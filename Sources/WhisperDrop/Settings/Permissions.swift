import Foundation

/// Contract file. Tracks and requests the macOS privacy permissions the live features need.
@MainActor
final class Permissions: ObservableObject {
    enum Kind: String, CaseIterable, Identifiable {
        case microphone, accessibility, inputMonitoring, systemAudio
        var id: String { rawValue }
    }
    enum Status { case granted, denied, unknown }
    @Published private(set) var status: [Kind: Status] = [:]
    /// Re-reads every status without prompting.
    func refresh() {}
    /// Shows the system prompt where one exists, otherwise opens the System Settings pane.
    func request(_ kind: Kind) {}
    func openSettings(_ kind: Kind) {}
}
