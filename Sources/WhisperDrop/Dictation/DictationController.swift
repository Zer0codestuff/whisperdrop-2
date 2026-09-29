import Foundation
import WhisperDropCore

/// Contract file. Push-to-talk state machine: hotkey -> microphone -> ModelHost -> TextInserter, with the HUD.
@MainActor
final class DictationController: ObservableObject {
    enum State: Equatable { case idle, listening(handsFree: Bool), transcribing, failed(String) }
    @Published private(set) var state: State = .idle
    /// Smoothed microphone level, 0...1, for the HUD meter.
    @Published private(set) var level: Float = 0
    /// Most recent dictations, newest first, at most 20. Kept in memory only.
    @Published private(set) var recent: [String] = []

    init(settings: AppSettings, host: ModelHost) {}
    /// Applies current settings (enabled, hotkey) and starts or stops the hotkey monitor.
    func refresh() {}
    /// Manual control, e.g. from the menu bar.
    func toggle() {}
    /// Stops listening without transcribing.
    func cancel() {}
    /// Copies the most recent dictation to the pasteboard.
    func copyLast() {}
}
