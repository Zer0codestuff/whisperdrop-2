import Foundation

/// Contract file. Watches the chosen modifier key globally and reports press/release.
@MainActor
final class HotkeyMonitor {
    enum Event { case pressed, released, cancelled }
    /// Called on the main actor. `cancelled` means another key was combined with the hotkey while held.
    var onEvent: ((Event) -> Void)?
    var hotkey: HotkeyChoice = .fn
    /// True when the monitor is running.
    private(set) var isRunning = false
    /// Starts monitoring; returns false if the required permission is missing.
    @discardableResult func start() -> Bool { false }
    func stop() {}
}
