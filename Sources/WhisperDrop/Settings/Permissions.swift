import Foundation
import AppKit
import AVFoundation
import ApplicationServices
import Combine

/// Contract file. Tracks and requests the macOS privacy permissions the live features need.
@MainActor
final class Permissions: ObservableObject {
    enum Kind: String, CaseIterable, Identifiable {
        case microphone, accessibility, inputMonitoring, systemAudio
        var id: String { rawValue }
    }
    enum Status { case granted, denied, unknown }
    @Published private(set) var status: [Kind: Status] = [:]

    private let defaults: UserDefaults
    private var activation: AnyCancellable?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        refresh()
        activation = NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in MainActor.assumeIsolated { self?.refresh() } }
    }

    /// Re-reads every status without prompting.
    func refresh() {
        var next: [Kind: Status] = [:]
        for kind in Kind.allCases { next[kind] = read(kind) }
        if next != status { status = next }
    }

    /// Shows the system prompt where one exists, otherwise opens the System Settings pane.
    func request(_ kind: Kind) {
        defer { refresh() }
        switch kind {
        case .microphone:
            guard AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined else { return openSettings(kind) }
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] _ in
                Task { @MainActor in self?.refresh() }
            }
        case .accessibility:
            // Synthetic Command-V needs the post-event grant, listed under Accessibility.
            // CGRequest* prompts only once per app, so later requests go to the pane.
            if read(kind) == .granted { return }
            if requested(kind) { return openSettings(kind) }
            markRequested(kind)
            if !CGRequestPostEventAccess() { openSettings(kind) }
        case .inputMonitoring:
            if read(kind) == .granted { return }
            if requested(kind) { return openSettings(kind) }
            markRequested(kind)
            if !CGRequestListenEventAccess() { openSettings(kind) }
        case .systemAudio:
            // No public preflight or request API: macOS prompts when a tap first records.
            openSettings(kind)
        }
    }

    func openSettings(_ kind: Kind) {
        let anchor = switch kind {
        case .microphone: "Privacy_Microphone"
        case .accessibility: "Privacy_Accessibility"
        case .inputMonitoring: "Privacy_ListenEvent"
        case .systemAudio: "Privacy_AudioCapture"
        }
        if let url = URL(string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?\(anchor)") {
            NSWorkspace.shared.open(url)
        }
    }

    private func read(_ kind: Kind) -> Status {
        switch kind {
        case .microphone:
            switch AVCaptureDevice.authorizationStatus(for: .audio) {
            case .authorized: return .granted
            case .denied, .restricted: return .denied
            default: return .unknown
            }
        case .accessibility:
            if CGPreflightPostEventAccess() || AXIsProcessTrusted() { return .granted }
            return requested(kind) ? .denied : .unknown
        case .inputMonitoring:
            if CGPreflightListenEventAccess() { return .granted }
            return requested(kind) ? .denied : .unknown
        case .systemAudio:
            // The recorder sets this flag after a tap delivered real audio.
            return defaults.bool(forKey: "systemAudioConfirmed") ? .granted : .unknown
        }
    }
    private func requested(_ kind: Kind) -> Bool { defaults.bool(forKey: "permissionRequested.\(kind.rawValue)") }
    private func markRequested(_ kind: Kind) { defaults.set(true, forKey: "permissionRequested.\(kind.rawValue)") }
}
