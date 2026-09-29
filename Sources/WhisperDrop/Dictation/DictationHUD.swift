import AppKit

/// Contract file. Small floating, non-activating panel near the bottom of the active screen.
@MainActor
final class DictationHUD {
    init(controller: DictationController) {}
    /// Shows or hides the panel to match the controller state. Called by the controller on every state change.
    func update() {}
}
