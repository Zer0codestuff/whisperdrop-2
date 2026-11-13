import AVFoundation
import CoreAudio
import Foundation
import os

/// Contract file. Captures one microphone as 16 kHz mono Float samples.
///
/// Capture runs a HAL IOProc on a device this class chooses, and holds no audio object while idle.
/// `AVAudioEngine` is not used here: its input node follows the default input, and binding it to a
/// Bluetooth headset moves the headset to its hands-free profile, 16 kHz mono playback, for as long as
/// the engine exists, even when it is stopped. See `docs/bluetooth-headset-playback.md`.
final class MicCapture: NoteCaptureSource, @unchecked Sendable {
    var droppedPacketCount: Int { handoff?.droppedPacketCount ?? 0 }
    /// Called on a background audio thread with 16 kHz mono samples.
    var onSamples: (@Sendable ([Float]) -> Void)? {
        didSet { listeners.withLockUnchecked { $0.samples = onSamples } }
    }
    /// Called on a background thread with the current input level, 0...1, about 20 times per second.
    var onLevel: (@Sendable (Float) -> Void)? {
        didSet { listeners.withLockUnchecked { $0.level = onLevel } }
    }

    private struct Listeners {
        var samples: (@Sendable ([Float]) -> Void)?
        var level: (@Sendable (Float) -> Void)?
    }

    private let resampler = Mono16kResampler()
    private let sessionQueue = DispatchQueue(label: "whisperdrop.microphone.session")
    private let sessionKey = DispatchSpecificKey<UInt8>()
    private let running = OSAllocatedUnfairLock(initialState: false)
    private let captureFailure = OSAllocatedUnfairLock<String?>(initialState: nil)
    var failureMessage: String? { captureFailure.withLockUnchecked { $0 } }
    private let listeners = OSAllocatedUnfairLock(initialState: Listeners())
    private let deviceEvents = DeviceEventRelay()
    private var handoff: PCMSlotQueue?
    private var chunker: InputChunker?
    private var device = AudioDeviceID(kAudioObjectUnknown)
    private var sourceFormat = AudioStreamBasicDescription()
    private var ioProc: AudioDeviceIOProcID?
    private var watched: [(object: AudioObjectID, address: AudioObjectPropertyAddress)] = []

    init() {
        sessionQueue.setSpecific(key: sessionKey, value: 1)
        deviceEvents.onEvent = { [weak self] in
            self?.sessionQueue.async { self?.handleDeviceChange() }
        }
    }

    deinit {
        stop()
    }

    /// Asks for microphone access if needed. Returns true when access is granted.
    static func requestAccess() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return true
        case .notDetermined:
            return await withCheckedContinuation { continuation in
                AVCaptureDevice.requestAccess(for: .audio) { granted in
                    continuation.resume(returning: granted)
                }
            }
        case .denied, .restricted:
            return false
        @unknown default:
            return false
        }
    }

    static var isAuthorized: Bool {
        AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    }

    /// Starts capturing. Throws a user-facing error if the device cannot be opened.
    func start() throws {
        guard Self.isAuthorized else { throw CaptureError.microphoneDenied }
        try onSession {
            if running.withLockUnchecked({ $0 }) { return }
            captureFailure.withLockUnchecked { $0 = nil }
            do {
                try open()
                running.withLockUnchecked { $0 = true }
            } catch {
                close()
                throw error
            }
        }
    }

    func stop() {
        onSession {
            running.withLockUnchecked { $0 = false }
            close()
        }
    }

    /// Opens the chosen device and starts its IOProc. The callback copies into `chunker`; conversion runs on the handoff worker.
    private func open() throws {
        guard let chosen = AudioInputDevices.preferredInput(),
              let format = AudioInputDevices.inputFormat(chosen) else {
            throw CaptureError.microphoneUnavailable("No microphone is available.")
        }
        guard let layout = InputChunker.Layout(source: format) else {
            throw CaptureError.microphoneUnavailable("The microphone uses an audio format WhisperDrop cannot read.")
        }
        let queue = prepareHandoff(payloadBytes: layout.chunkFrames * MemoryLayout<Float>.size)
        queue.start()
        let chunker = InputChunker(layout: layout, queue: queue)
        self.chunker = chunker

        var created: AudioDeviceIOProcID?
        let createStatus = AudioDeviceCreateIOProcIDWithBlock(&created, chosen, nil) { _, input, _, output, _ in
            // Real-time thread: copy only. A device that also plays gets silence from this client.
            for buffer in UnsafeMutableAudioBufferListPointer(output) {
                if let data = buffer.mData { memset(data, 0, Int(buffer.mDataByteSize)) }
            }
            chunker.append(input)
        }
        guard createStatus == noErr, let created else {
            throw CaptureError.microphoneUnavailable("The audio device refused the capture callback (error \(createStatus)).")
        }
        device = chosen
        sourceFormat = format
        ioProc = created
        let startStatus = AudioDeviceStart(chosen, created)
        guard startStatus == noErr else {
            throw CaptureError.microphoneUnavailable("The audio device did not start (error \(startStatus)).")
        }
        watch(chosen)
    }

    /// Stops IO first, which clears the microphone indicator, then drains what was already captured.
    private func close() {
        unwatch()
        if let ioProc, device != kAudioObjectUnknown {
            AudioDeviceStop(device, ioProc)
            AudioDeviceDestroyIOProcID(device, ioProc)
        }
        ioProc = nil
        device = AudioDeviceID(kAudioObjectUnknown)
        // The last partial chunk goes through the queue before its worker exits.
        chunker?.flush()
        chunker = nil
        handoff?.stop()
        // The worker has exited, so the converter is idle. Emit the filter tail before the next start.
        emit(resampler.flush())
    }

    private func prepareHandoff(payloadBytes: Int) -> PCMSlotQueue {
        if let handoff, handoff.payloadCapacity >= payloadBytes {
            return handoff
        }
        handoff?.stop()
        let queue = PCMSlotQueue(payloadCapacity: max(payloadBytes, 16_384), label: "whisperdrop.microphone") { [weak self] packet in
            guard let self, let buffer = PCMBuffers.make(packet) else { return }
            self.emit(self.resampler.convert(buffer: buffer))
        }
        handoff = queue
        return queue
    }

    /// The default input, the device itself or its format changed. Reopen only when the choice or format differs.
    private func handleDeviceChange() {
        guard running.withLockUnchecked({ $0 }) else { return }
        if device != kAudioObjectUnknown,
           AudioInputDevices.isAlive(device),
           AudioInputDevices.preferredInput() == device,
           let format = AudioInputDevices.inputFormat(device),
           InputChunker.Layout(source: format) == InputChunker.Layout(source: sourceFormat) {
            return
        }
        close()
        do {
            try open()
        } catch {
            running.withLockUnchecked { $0 = false }
            captureFailure.withLockUnchecked { $0 = error.localizedDescription }
            close()
        }
    }

    private func watch(_ device: AudioDeviceID) {
        let system = AudioObjectID(kAudioObjectSystemObject)
        let global = kAudioObjectPropertyScopeGlobal
        let targets: [(AudioObjectID, AudioObjectPropertySelector, AudioObjectPropertyScope)] = [
            (system, kAudioHardwarePropertyDefaultInputDevice, global),
            (device, kAudioDevicePropertyDeviceIsAlive, global),
            (device, kAudioDevicePropertyNominalSampleRate, global),
            (device, kAudioDevicePropertyStreamConfiguration, kAudioObjectPropertyScopeInput),
        ]
        for (object, selector, scope) in targets {
            var address = AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
            if AudioObjectAddPropertyListener(object, &address, DeviceEventRelay.callback, deviceEvents.context) == noErr {
                watched.append((object, address))
            }
        }
    }

    private func unwatch() {
        for entry in watched {
            var address = entry.address
            AudioObjectRemovePropertyListener(entry.object, &address, DeviceEventRelay.callback, deviceEvents.context)
        }
        watched.removeAll()
    }

    private func emit(_ samples: [Float]) {
        guard !samples.isEmpty else { return }
        let handlers = listeners.withLockUnchecked { $0 }
        handlers.samples?(samples)
        // 800 frames at 16 kHz is 50 ms, about 20 level updates per second of audio.
        let window = 800
        var index = 0
        while index + window <= samples.count {
            handlers.level?(CaptureLevel.rms(samples[index..<(index + window)]))
            index += window
        }
    }

    private func onSession<T>(_ body: () throws -> T) rethrows -> T {
        if DispatchQueue.getSpecific(key: sessionKey) == 1 {
            return try body()
        }
        return try sessionQueue.sync(execute: body)
    }
}

/// Context for the C property listener. Swift closures passed to the block listener API cannot be removed again.
private final class DeviceEventRelay: @unchecked Sendable {
    var onEvent: (() -> Void)?

    var context: UnsafeMutableRawPointer { Unmanaged.passUnretained(self).toOpaque() }

    static let callback: AudioObjectPropertyListenerProc = { _, _, _, context in
        guard let context else { return noErr }
        Unmanaged<DeviceEventRelay>.fromOpaque(context).takeUnretainedValue().onEvent?()
        return noErr
    }
}

/// Collects HAL input packets, about 10 ms each, into 100 ms mono chunks for the slot queue.
///
/// Only the first channel of the first input stream is kept. The converter this replaces also kept
/// only the first channel of a stereo input.
final class InputChunker: @unchecked Sendable {
    struct Layout: Equatable {
        let sampleRate: Double
        /// Float samples per frame in the first buffer of each callback.
        let stride: Int
        let chunkFrames: Int

        /// Nil unless the stream is native 32-bit float PCM, which is what the HAL delivers to an IOProc.
        init?(source: AudioStreamBasicDescription) {
            let flags = source.mFormatFlags
            guard source.mFormatID == kAudioFormatLinearPCM,
                  flags & kAudioFormatFlagIsFloat != 0,
                  flags & kAudioFormatFlagIsBigEndian == 0,
                  source.mBitsPerChannel == 32,
                  source.mSampleRate.isFinite, source.mSampleRate > 0,
                  source.mChannelsPerFrame > 0 else {
                return nil
            }
            let interleaved = flags & kAudioFormatFlagIsNonInterleaved == 0
            sampleRate = source.mSampleRate
            stride = interleaved ? Int(source.mChannelsPerFrame) : 1
            chunkFrames = max(Int((source.mSampleRate * 0.1).rounded()), 256)
        }
    }

    private let layout: Layout
    private let format: AudioStreamBasicDescription
    private let samples: UnsafeMutablePointer<Float>
    private var count = 0
    private let lock = OSAllocatedUnfairLock()
    private let queue: PCMSlotQueue

    init(layout: Layout, queue: PCMSlotQueue) {
        self.layout = layout
        self.queue = queue
        let bytes = UInt32(MemoryLayout<Float>.size)
        format = AudioStreamBasicDescription(
            mSampleRate: layout.sampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked | kAudioFormatFlagIsNonInterleaved,
            mBytesPerPacket: bytes,
            mFramesPerPacket: 1,
            mBytesPerFrame: bytes,
            mChannelsPerFrame: 1,
            mBitsPerChannel: 32,
            mReserved: 0
        )
        samples = .allocate(capacity: layout.chunkFrames)
        samples.initialize(repeating: 0, count: layout.chunkFrames)
    }

    deinit {
        samples.deinitialize(count: layout.chunkFrames)
        samples.deallocate()
    }

    /// Real-time thread. Never waits: a callback that meets `flush` is dropped, and capture is stopping then.
    func append(_ list: UnsafePointer<AudioBufferList>) {
        lock.withLockIfAvailableUnchecked {
            let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: list))
            guard let first = buffers.first, let data = first.mData else { return }
            let source = data.assumingMemoryBound(to: Float.self)
            var remaining = Int(first.mDataByteSize) / (MemoryLayout<Float>.size * layout.stride)
            var offset = 0
            while remaining > 0 {
                let take = min(remaining, layout.chunkFrames - count)
                if layout.stride == 1 {
                    (samples + count).update(from: source + offset, count: take)
                } else {
                    for index in 0..<take {
                        samples[count + index] = source[(offset + index) * layout.stride]
                    }
                }
                count += take
                offset += take
                remaining -= take
                if count == layout.chunkFrames { publish() }
            }
        }
    }

    /// Publishes a partial chunk. Call after the IOProc has stopped.
    func flush() {
        lock.withLockUnchecked {
            if count > 0 { publish() }
        }
    }

    private func publish() {
        var list = AudioBufferList(
            mNumberBuffers: 1,
            mBuffers: AudioBuffer(
                mNumberChannels: 1,
                mDataByteSize: UInt32(count * MemoryLayout<Float>.size),
                mData: UnsafeMutableRawPointer(samples)
            )
        )
        queue.publish(format: format, list: &list)
        count = 0
    }
}
