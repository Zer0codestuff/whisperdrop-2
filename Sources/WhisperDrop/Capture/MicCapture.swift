import AudioToolbox
import AVFoundation
import Foundation
import os

/// Contract file. Captures the default input device as 16 kHz mono Float samples.
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

    /// One engine for the life of the object. `start` reuses it so dictation does not rebuild the graph.
    private let engine = AVAudioEngine()
    private let resampler = Mono16kResampler()
    private let sessionQueue = DispatchQueue(label: "whisperdrop.microphone.session")
    private let sessionKey = DispatchSpecificKey<UInt8>()
    private let running = OSAllocatedUnfairLock(initialState: false)
    private let listeners = OSAllocatedUnfairLock(initialState: Listeners())
    private var handoff: PCMSlotQueue?
    private var configObserver: NSObjectProtocol?
    private var tapInstalled = false
    private var reconfiguring = false

    init() {
        sessionQueue.setSpecific(key: sessionKey, value: 1)
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
            do {
                try installTapAndStart()
            } catch {
                running.withLockUnchecked { $0 = false }
                releaseEngine()
                throw error
            }
        }
    }

    func stop() {
        onSession {
            running.withLockUnchecked { $0 = false }
            releaseEngine()
            if let configObserver {
                NotificationCenter.default.removeObserver(configObserver)
                self.configObserver = nil
            }
        }
    }

    /// `AVAudioEngine` input tap. The hardware buffer is copied into `handoff` and converted off the audio thread.
    private func installTapAndStart() throws {
        // Opening a Bluetooth headset mic drops that headset into its low-quality speaking mode.
        // Point the input unit at the built-in mic when there is one, and leave the system output alone.
        preferBuiltInInputIfBluetooth()
        let input = engine.inputNode
        let hardware = input.outputFormat(forBus: 0)
        guard hardware.sampleRate > 0, hardware.channelCount > 0 else {
            throw CaptureError.microphoneUnavailable("No microphone is available.")
        }
        prepareHandoff(for: hardware)
        handoff?.start()
        if tapInstalled {
            input.removeTap(onBus: 0)
            tapInstalled = false
        }
        let bufferSize = Self.bufferSize(for: hardware)
        install(on: input, bufferSize: bufferSize, format: hardware)
        if configObserver == nil {
            // The engine posts this on an internal queue and has already stopped itself.
            // Do not deallocate the engine from that callback.
            configObserver = NotificationCenter.default.addObserver(
                forName: .AVAudioEngineConfigurationChange,
                object: engine,
                queue: nil
            ) { [weak self] _ in
                // Posted on an internal engine queue. Hop off before touching the engine.
                self?.sessionQueue.async {
                    self?.handleConfigurationChange()
                }
            }
        }
        // Set before `start` so the first buffers are not dropped.
        running.withLockUnchecked { $0 = true }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            throw CaptureError.microphoneUnavailable(error.localizedDescription)
        }
    }

    private func install(on input: AVAudioInputNode, bufferSize: AVAudioFrameCount, format: AVAudioFormat) {
        let block: AVAudioNodeTapBlock = { [weak self] buffer, _ in
            guard let self else { return }
            guard self.running.withLockIfAvailableUnchecked({ $0 }) == true else { return }
            self.handoff?.publish(buffer)
        }
        // The error-returning replacement is macOS 27 only. The void method remains the one this deployment target can call.
        input.installTap(onBus: 0, bufferSize: bufferSize, format: format, block: block)
        tapInstalled = true
    }

    /// Header documents the supported tap size as 100...400 ms. 100 ms keeps dictation callbacks short.
    private static func bufferSize(for format: AVAudioFormat) -> AVAudioFrameCount {
        let minimum = format.sampleRate * 0.1
        let maximum = format.sampleRate * 0.4
        return AVAudioFrameCount(min(max(minimum, 1_024), maximum))
    }

    private func prepareHandoff(for format: AVAudioFormat) {
        let description = format.streamDescription.pointee
        let frames = min(max(Int(format.sampleRate * 0.4), 4_096), 32_768)
        let bytesPerFrame = max(Int(description.mBytesPerFrame), 1)
        let channels = max(Int(description.mChannelsPerFrame), 1)
        let nonInterleaved = (description.mFormatFlags & kAudioFormatFlagIsNonInterleaved) != 0
        let bytes = frames * bytesPerFrame * (nonInterleaved ? channels : 1)
        if let handoff, handoff.payloadCapacity >= bytes {
            return
        }
        handoff?.stop()
        handoff = PCMSlotQueue(payloadCapacity: bytes, label: "whisperdrop.microphone") { [weak self] packet in
            guard let self, let buffer = PCMBuffers.make(packet) else { return }
            self.emit(self.resampler.convert(buffer: buffer))
        }
    }

    private func preferBuiltInInputIfBluetooth() {
        guard let current = AudioInputDevices.defaultInput(),
              AudioInputDevices.isBluetooth(current),
              let builtIn = AudioInputDevices.builtInInput(),
              let unit = engine.inputNode.audioUnit else {
            return
        }
        var device = builtIn
        // Scope is global. This does not change the system default output device.
        AudioUnitSetProperty(
            unit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &device,
            UInt32(MemoryLayout<AudioDeviceID>.size)
        )
    }

    private func handleConfigurationChange() {
        let active = running.withLockUnchecked { $0 }
        guard active, !reconfiguring else { return }
        reconfiguring = true
        defer { reconfiguring = false }
        if tapInstalled {
            engine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }
        do {
            try installTapAndStart()
        } catch {
            running.withLockUnchecked { $0 = false }
            releaseEngine()
        }
    }

    /// `engine.stop()` releases the input device, which clears the microphone indicator.
    private func releaseEngine() {
        if tapInstalled {
            engine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }
        engine.stop()
        handoff?.stop()
        // The worker has exited, so the converter is idle. Emit the filter tail before the next start.
        emit(resampler.flush())
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
