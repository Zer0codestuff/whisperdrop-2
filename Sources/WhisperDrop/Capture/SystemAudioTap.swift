import AVFoundation
import AudioToolbox
import CoreAudio
import CoreGraphics
import CoreMedia
import Foundation
import os
import ScreenCaptureKit

/// Contract file. Captures audio played by other apps (meeting participants) as 16 kHz mono Float samples.
final class SystemAudioTap: @unchecked Sendable {
    /// Called on a background audio thread with 16 kHz mono samples.
    var onSamples: (@Sendable ([Float]) -> Void)? {
        didSet { listeners.withLockUnchecked { $0.samples = onSamples } }
    }
    var onLevel: (@Sendable (Float) -> Void)? {
        didSet { listeners.withLockUnchecked { $0.level = onLevel } }
    }

    /// False on systems where system audio capture is unavailable.
    /// This package requires macOS 14, so either the process tap (14.2 and later) or ScreenCaptureKit audio (14.0 and 14.1) exists.
    static var isSupported: Bool { true }

    private struct Listeners {
        var samples: (@Sendable ([Float]) -> Void)?
        var level: (@Sendable (Float) -> Void)?
    }

    private let session = NSLock()
    private let listeners = OSAllocatedUnfairLock(initialState: Listeners())
    private let resampler = Mono16kResampler()
    private let screenQueue = DispatchQueue(label: "whisperdrop.system-audio.screen")
    private let screenKey = DispatchSpecificKey<UInt8>()
    private var running = false
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var ioProc: AudioDeviceIOProcID?
    private var handoff: PCMSlotQueue?
    private var screenStream: SCStream?
    private var screenOutput: ScreenAudioOutput?

    init() {
        screenQueue.setSpecific(key: screenKey, value: 1)
    }

    deinit {
        stop()
    }

    /// Starts capturing. The first call may show the System Audio Recording permission prompt. Throws a user-facing error on failure.
    func start() throws {
        session.lock()
        defer { session.unlock() }
        if running { return }
        do {
            if #available(macOS 14.2, *) {
                try startProcessTap()
            } else {
                try startScreenCapture()
            }
            running = true
        } catch {
            tearDown()
            running = false
            throw error
        }
    }

    func stop() {
        session.lock()
        defer { session.unlock() }
        guard running || tapID != kAudioObjectUnknown || aggregateID != kAudioObjectUnknown || screenStream != nil else {
            return
        }
        running = false
        tearDown()
    }

    /// Global stereo mix of every process except this one. Private tap, unmuted, private aggregate.
    @available(macOS 14.2, *)
    private func startProcessTap() throws {
        let processID = try? Self.currentProcessObjectID()
        if processID == nil {
            guard #available(macOS 26.0, *), Bundle.main.bundleIdentifier != nil else {
                throw CaptureError.systemAudioFailed("System audio capture could not exclude this app yet. Start the microphone, then try again.")
            }
        }
        let tapDescription = CATapDescription(stereoGlobalTapButExcludeProcesses: processID.map { [$0] } ?? [])
        tapDescription.name = "WhisperDrop Others"
        tapDescription.isPrivate = true
        tapDescription.muteBehavior = .unmuted
        if #available(macOS 26.0, *), let bundleID = Bundle.main.bundleIdentifier {
            tapDescription.bundleIDs = [bundleID]
        }
        let tapUID = tapDescription.uuid.uuidString

        var createdTap = AudioObjectID(kAudioObjectUnknown)
        let tapStatus = AudioHardwareCreateProcessTap(tapDescription, &createdTap)
        guard tapStatus == noErr, createdTap != kAudioObjectUnknown else {
            throw SystemAudioErrors.failed("creating the process tap", status: tapStatus)
        }
        tapID = createdTap

        let tapEntry: [String: Any] = [
            kAudioSubTapUIDKey as String: tapUID,
            kAudioSubTapDriftCompensationKey as String: NSNumber(value: 1),
        ]
        let aggregate: [String: Any] = [
            kAudioAggregateDeviceNameKey as String: "WhisperDrop System Tap",
            kAudioAggregateDeviceUIDKey as String: UUID().uuidString,
            kAudioAggregateDeviceIsPrivateKey as String: NSNumber(value: 1),
            kAudioAggregateDeviceIsStackedKey as String: NSNumber(value: 0),
            // 0: AudioDeviceStart must not wait for the first non-silent buffer.
            kAudioAggregateDeviceTapAutoStartKey as String: NSNumber(value: 0),
            kAudioAggregateDeviceTapListKey as String: [tapEntry],
        ]
        var createdAggregate = AudioObjectID(kAudioObjectUnknown)
        let aggregateStatus = AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &createdAggregate)
        guard aggregateStatus == noErr, createdAggregate != kAudioObjectUnknown else {
            throw SystemAudioErrors.failed("creating the aggregate device", status: aggregateStatus)
        }
        aggregateID = createdAggregate

        let format: AudioStreamBasicDescription
        do {
            format = try readInputFormat(createdAggregate)
        } catch {
            throw error
        }
        guard format.mSampleRate > 0, format.mChannelsPerFrame > 0 else {
            throw CaptureError.systemAudioFailed("System audio capture returned an empty format.")
        }

        let queue = makeHandoff(format: format, device: createdAggregate)
        queue.start()
        handoff = queue

        var createdProc: AudioDeviceIOProcID?
        let procStatus = AudioDeviceCreateIOProcIDWithBlock(&createdProc, createdAggregate, nil) { _, inputData, _, _, _ in
            // Real-time thread: copy into a slot. The queue converts and resamples.
            queue.publish(format: format, list: inputData)
        }
        guard procStatus == noErr, let createdProc else {
            throw SystemAudioErrors.failed("installing the audio callback", status: procStatus)
        }
        ioProc = createdProc
        let startStatus = AudioDeviceStart(createdAggregate, createdProc)
        guard startStatus == noErr else {
            throw SystemAudioErrors.failed("starting the audio device", status: startStatus)
        }
    }

    /// Audio-only ScreenCaptureKit path for macOS 14.0 and 14.1, where process taps do not exist.
    private func startScreenCapture() throws {
        if !CGPreflightScreenCaptureAccess() {
            let granted: Bool
            if Thread.isMainThread {
                granted = CGRequestScreenCaptureAccess()
            } else {
                granted = DispatchQueue.main.sync { CGRequestScreenCaptureAccess() }
            }
            if !granted { throw CaptureError.screenRecordingNeeded }
            // CGWindow.h: a grant does not apply to this process until it is launched again.
            throw CaptureError.screenRecordingNeedsRelaunch
        }

        let content: SCShareableContent = try awaitCaptureCallback { callback in
            SCShareableContent.getExcludingDesktopWindows(true, onScreenWindowsOnly: true) { content, error in
                if let content {
                    callback(.success(content))
                } else {
                    callback(.failure(error ?? CaptureError.systemAudioFailed("No shareable audio source is available.")))
                }
            }
        }
        let mainID = CGMainDisplayID()
        guard let display = content.displays.first(where: { $0.displayID == mainID }) ?? content.displays.first else {
            throw CaptureError.systemAudioFailed("No display is available for system audio capture.")
        }
        let bundleID = Bundle.main.bundleIdentifier
        let excluded = content.applications.filter { $0.bundleIdentifier == bundleID }
        let filter = SCContentFilter(display: display, excludingApplications: excluded, exceptingWindows: [])
        let configuration = SCStreamConfiguration()
        configuration.capturesAudio = true
        configuration.excludesCurrentProcessAudio = true
        configuration.sampleRate = 48_000
        configuration.channelCount = 2
        // Width and height stay at the header defaults. Passing 0 is not a documented audio-only size.

        let output = ScreenAudioOutput(owner: self)
        let stream = SCStream(filter: filter, configuration: configuration, delegate: nil)
        do {
            try stream.addStreamOutput(output, type: .audio, sampleHandlerQueue: screenQueue)
        } catch {
            throw CaptureError.systemAudioFailed("System audio capture could not be started. \(error.localizedDescription)")
        }
        screenOutput = output
        screenStream = stream
        do {
            try awaitCaptureCallback { (callback: @escaping (Result<Void, Error>) -> Void) in
                stream.startCapture { error in
                    if let error {
                        callback(.failure(error))
                    } else {
                        callback(.success(()))
                    }
                }
            }
        } catch {
            throw CaptureError.systemAudioFailed("System audio capture could not be started. \(error.localizedDescription)")
        }
    }

    fileprivate func handleScreenSample(_ sample: CMSampleBuffer) {
        guard CMSampleBufferIsValid(sample), CMSampleBufferDataIsReady(sample) else { return }
        guard let description = sample.formatDescription,
              let basic = CMAudioFormatDescriptionGetStreamBasicDescription(description) else {
            return
        }
        var streamDescription = basic.pointee
        let frames = AVAudioFrameCount(CMSampleBufferGetNumSamples(sample))
        guard frames > 0,
              let format = AVAudioFormat(streamDescription: &streamDescription),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else {
            return
        }
        buffer.frameLength = frames
        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sample,
            at: 0,
            frameCount: Int32(frames),
            into: buffer.mutableAudioBufferList
        )
        guard status == noErr else { return }
        emit(resampler.convert(buffer: buffer))
    }

    /// Stop IO, destroy the IOProc, destroy the aggregate, then destroy the tap.
    /// Aggregate destruction is asynchronous (AudioHardware.h). The tap is destroyed after the aggregate call returns.
    private func tearDown() {
        let proc = ioProc
        let aggregate = aggregateID
        let tap = tapID
        ioProc = nil
        aggregateID = AudioObjectID(kAudioObjectUnknown)
        tapID = AudioObjectID(kAudioObjectUnknown)
        if let proc, aggregate != kAudioObjectUnknown {
            AudioDeviceStop(aggregate, proc)
            AudioDeviceDestroyIOProcID(aggregate, proc)
        }
        if aggregate != kAudioObjectUnknown {
            AudioHardwareDestroyAggregateDevice(aggregate)
        }
        if tap != kAudioObjectUnknown {
            if #available(macOS 14.2, *) {
                AudioHardwareDestroyProcessTap(tap)
            }
        }

        let usedScreen = screenStream != nil
        if let stream = screenStream {
            screenStream = nil
            let output = screenOutput
            screenOutput = nil
            let semaphore = DispatchSemaphore(value: 0)
            stream.stopCapture { _ in semaphore.signal() }
            if Thread.isMainThread {
                let deadline = Date().addingTimeInterval(2)
                while semaphore.wait(timeout: .now()) == .timedOut, Date() < deadline {
                    RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.05))
                }
            } else {
                _ = semaphore.wait(timeout: .now() + 2)
            }
            if let output {
                try? stream.removeStreamOutput(output, type: .audio)
            }
        }
        handoff?.stop()
        handoff = nil
        // Flush only after the consumer queue has drained, and on that same queue.
        if usedScreen {
            onScreen { self.emit(self.resampler.flush()) }
        } else {
            emit(resampler.flush())
        }
    }

    private func onScreen(_ body: () -> Void) {
        if DispatchQueue.getSpecific(key: screenKey) == 1 {
            body()
        } else {
            screenQueue.sync(execute: body)
        }
    }

    private func makeHandoff(format: AudioStreamBasicDescription, device: AudioObjectID) -> PCMSlotQueue {
        let frames = min(max(maximumBufferFrames(device), 4_096), 32_768)
        let bytesPerFrame = max(Int(format.mBytesPerFrame), 1)
        let channels = max(Int(format.mChannelsPerFrame), 1)
        let nonInterleaved = (format.mFormatFlags & kAudioFormatFlagIsNonInterleaved) != 0
        let bytes = frames * bytesPerFrame * (nonInterleaved ? channels : 1)
        return PCMSlotQueue(payloadCapacity: max(bytes, 16_384), label: "whisperdrop.system-audio") { [weak self] packet in
            guard let self, let buffer = PCMBuffers.make(packet) else { return }
            self.emit(self.resampler.convert(buffer: buffer))
        }
    }

    private func emit(_ samples: [Float]) {
        guard !samples.isEmpty else { return }
        let handlers = listeners.withLockUnchecked { $0 }
        handlers.samples?(samples)
        let window = 800
        var index = 0
        while index + window <= samples.count {
            handlers.level?(CaptureLevel.rms(samples[index..<(index + window)]))
            index += window
        }
    }

    private func maximumBufferFrames(_ device: AudioObjectID) -> Int {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyBufferFrameSizeRange,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var range = AudioValueRange(mMinimum: 0, mMaximum: 4_096)
        var size = UInt32(MemoryLayout<AudioValueRange>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &range) == noErr else {
            return 16_384
        }
        return Int(range.mMaximum)
    }

    private static func currentProcessObjectID() throws -> AudioObjectID {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var pid = getpid()
        var objectID = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            UInt32(MemoryLayout<pid_t>.size),
            &pid,
            &size,
            &objectID
        )
        // The header returns kAudioObjectUnknown, not an error, when this process is not a HAL client yet.
        guard status == noErr, objectID != kAudioObjectUnknown else {
            throw CaptureError.systemAudioFailed("System audio capture could not exclude this app yet. Start the microphone, then try again.")
        }
        return objectID
    }

    private func readInputFormat(_ device: AudioObjectID) throws -> AudioStreamBasicDescription {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamFormat,
            mScope: kAudioObjectPropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var format = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        let status = AudioObjectGetPropertyData(device, &address, 0, nil, &size, &format)
        guard status == noErr else {
            throw SystemAudioErrors.failed("reading the tap format", status: status)
        }
        return format
    }
}

private final class ScreenAudioOutput: NSObject, SCStreamOutput {
    weak var owner: SystemAudioTap?

    init(owner: SystemAudioTap) {
        self.owner = owner
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio else { return }
        owner?.handleScreenSample(sampleBuffer)
    }
}
