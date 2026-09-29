import Foundation

/// Contract file. Captures the default input device as 16 kHz mono Float samples.
final class MicCapture: @unchecked Sendable {
    /// Called on a background audio thread with 16 kHz mono samples.
    var onSamples: (@Sendable ([Float]) -> Void)?
    /// Called on a background thread with the current input level, 0...1, about 20 times per second.
    var onLevel: (@Sendable (Float) -> Void)?
    /// Asks for microphone access if needed. Returns true when access is granted.
    static func requestAccess() async -> Bool { false }
    static var isAuthorized: Bool { false }
    /// Starts capturing. Throws a user-facing error if the device cannot be opened.
    func start() throws {}
    func stop() {}
}
