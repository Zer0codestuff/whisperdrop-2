import AudioToolbox
import CoreAudio
import Foundation
import os

/// User-facing failures from microphone and system-audio capture.
enum CaptureError: LocalizedError {
    case microphoneDenied
    case microphoneUnavailable(String)
    case systemAudioFailed(String)
    case screenRecordingNeeded
    case screenRecordingNeedsRelaunch
    case fileFailed(String)

    var errorDescription: String? {
        switch self {
        case .microphoneDenied:
            return "Microphone access is not granted. Allow microphone access for WhisperDrop in System Settings and try again."
        case .microphoneUnavailable(let detail):
            return "The microphone could not be opened. \(detail)"
        case .systemAudioFailed(let detail):
            return detail
        case .screenRecordingNeeded:
            return "Screen Recording permission is required to capture system audio on this version of macOS. Enable WhisperDrop in Privacy & Security and try again."
        case .screenRecordingNeedsRelaunch:
            return "Screen Recording was granted. Quit and reopen WhisperDrop, then start system audio capture again."
        case .fileFailed(let detail):
            return detail
        }
    }
}

enum CaptureLevel {
    /// Root mean square in 0...1.
    static func rms(_ samples: ArraySlice<Float>) -> Float {
        guard !samples.isEmpty else { return 0 }
        var sum: Float = 0
        for sample in samples {
            sum += sample * sample
        }
        return min(1, sqrt(sum / Float(samples.count)))
    }
}

enum AudioInputDevices {
    static func defaultInput() -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var device = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device
        )
        guard status == noErr, device != kAudioObjectUnknown else { return nil }
        return device
    }

    /// Built-in device that has at least one input stream, when the Mac has one.
    static func builtInInput() -> AudioDeviceID? {
        allDevices().first { transport($0) == kAudioDeviceTransportTypeBuiltIn && inputStreamCount($0) > 0 }
    }

    static func isBluetooth(_ device: AudioDeviceID) -> Bool {
        let kind = transport(device)
        return kind == kAudioDeviceTransportTypeBluetooth || kind == kAudioDeviceTransportTypeBluetoothLE
    }

    private static func allDevices() -> [AudioDeviceID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        let system = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        let count = Int(size) / MemoryLayout<AudioDeviceID>.size
        var devices = [AudioDeviceID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &devices) == noErr else { return [] }
        return devices
    }

    private static func transport(_ device: AudioDeviceID) -> UInt32? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr else { return nil }
        return value
    }

    private static func inputStreamCount(_ device: AudioDeviceID) -> Int {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: kAudioObjectPropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size) == noErr else { return 0 }
        return Int(size) / MemoryLayout<AudioStreamID>.size
    }
}

enum SystemAudioErrors {
    static func failed(_ operation: String, status: OSStatus) -> CaptureError {
        if status == kAudioDevicePermissionsError {
            return .systemAudioFailed("System audio recording permission was denied. Allow System Audio Recording for WhisperDrop in Privacy & Security and try again.")
        }
        if status == kAudioHardwareBadDeviceError || status == kAudioHardwareBadObjectError {
            return .systemAudioFailed("The audio device could not be opened while \(operation).")
        }
        return .systemAudioFailed("Could not start system audio capture while \(operation). Allow System Audio Recording for WhisperDrop in Privacy & Security and try again.")
    }
}

/// Waits for a callback without deadlocking when that callback arrives on the main queue.
func awaitCaptureCallback<T>(
    timeout: TimeInterval = 8,
    _ start: (@escaping (Result<T, Error>) -> Void) -> Void
) throws -> T {
    let box = CallbackBox<T>()
    let semaphore = DispatchSemaphore(value: 0)
    start { result in
        box.lock.withLockUnchecked { box.result = result }
        semaphore.signal()
    }
    let deadline = Date().addingTimeInterval(timeout)
    if Thread.isMainThread {
        while semaphore.wait(timeout: .now()) == .timedOut {
            if Date() > deadline {
                throw CaptureError.systemAudioFailed("Timed out while starting system audio capture.")
            }
            RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.05))
        }
    } else if semaphore.wait(timeout: .now() + timeout) == .timedOut {
        throw CaptureError.systemAudioFailed("Timed out while starting system audio capture.")
    }
    let result = box.lock.withLockUnchecked { box.result }
    guard let result else {
        throw CaptureError.systemAudioFailed("System audio capture did not start.")
    }
    return try result.get()
}

private final class CallbackBox<T>: @unchecked Sendable {
    let lock = OSAllocatedUnfairLock()
    var result: Result<T, Error>?
}

extension Data {
    mutating func appendBigEndian<T: FixedWidthInteger>(_ value: T) {
        var big = value.bigEndian
        Swift.withUnsafeBytes(of: &big) { append(contentsOf: $0) }
    }

    mutating func appendBigEndian(_ value: Float64) {
        appendBigEndian(value.bitPattern)
    }
}
