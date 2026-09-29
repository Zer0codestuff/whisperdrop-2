import Foundation

/// Contract file. Captures audio played by other apps (meeting participants) as 16 kHz mono Float samples.
final class SystemAudioTap: @unchecked Sendable {
    /// Called on a background audio thread with 16 kHz mono samples.
    var onSamples: (@Sendable ([Float]) -> Void)?
    var onLevel: (@Sendable (Float) -> Void)?
    /// False on systems where system audio capture is unavailable.
    static var isSupported: Bool { false }
    /// Starts capturing. The first call may show the System Audio Recording permission prompt. Throws a user-facing error on failure.
    func start() throws {}
    func stop() {}
}
