import SwiftUI
import AppKit
import WhisperDropCore

/// Shared look for the dictation, notes, menu bar and settings views.
/// Mirrors the private palette and buttons in ContentView.swift under different names.
enum LivePalette {
    static let green = Color(red: 43 / 255, green: 214 / 255, blue: 107 / 255)
    static let secondary = Color(white: 0.65)
    static let line = Color(white: 0.165)
    static let selected = Color(red: 13 / 255, green: 32 / 255, blue: 20 / 255)
    static let sidebar = Color(white: 0.035)
    static let surface = Color(white: 0.07)
}

struct LiveQuietButton: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size: 12, weight: .medium)).padding(.horizontal, 12).padding(.vertical, 8)
            .background(Color.white.opacity(configuration.isPressed ? 0.14 : 0.065), in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(LivePalette.line))
            .opacity(enabled ? 1 : 0.45)
    }
}

struct LiveGreenButton: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size: 12, weight: .semibold)).foregroundStyle(enabled ? .black : LivePalette.secondary)
            .padding(.horizontal, 16).padding(.vertical, 9)
            .background(enabled ? LivePalette.green.opacity(configuration.isPressed ? 0.75 : 1) : Color.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 8))
    }
}

/// Native glass for small control groups on macOS 26+, opaque elsewhere and with Reduce Transparency.
struct LiveControlSurface: ViewModifier {
    var radius: CGFloat = 18
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @ViewBuilder func body(content: Content) -> some View {
        if #available(macOS 26, *), !reduceTransparency {
            content.glassEffect(.regular, in: RoundedRectangle(cornerRadius: radius))
        } else {
            content.background(LivePalette.surface, in: RoundedRectangle(cornerRadius: radius))
                .overlay(RoundedRectangle(cornerRadius: radius).strokeBorder(LivePalette.line))
        }
    }
}

/// Static green waveform used on empty screens and in the guide.
struct LiveWaveMark: View {
    var scale: CGFloat = 1
    var body: some View {
        HStack(spacing: 6 * scale) {
            ForEach(Array([16.0, 30, 48, 64, 38, 22, 12].enumerated()), id: \.offset) { _, height in
                Capsule().fill(LivePalette.green).frame(width: 5 * scale, height: height * scale)
            }
        }
    }
}

/// Five green capsules driven by a 0...1 level.
struct LiveLevelBars: View {
    var level: Float
    var active = true
    var color = LivePalette.green
    var maxHeight: CGFloat = 16
    private let weights: [CGFloat] = [0.55, 0.85, 1, 0.8, 0.6]
    var body: some View {
        // Perceptual curve so quiet speech still moves the bars.
        let value = active ? CGFloat(sqrt(min(max(level, 0), 1))) : 0
        HStack(alignment: .center, spacing: 3) {
            ForEach(weights.indices, id: \.self) { i in
                Capsule().fill(color.opacity(active ? 1 : 0.4))
                    .frame(width: 3, height: max(4, maxHeight * min(1, value * weights[i] * 1.25)))
            }
        }
        .frame(height: maxHeight)
        .animation(.linear(duration: 0.08), value: value)
        .accessibilityHidden(true)
    }
}

enum LiveFormat {
    /// `m:ss` below one hour, then `h:mm:ss`.
    static func clock(_ seconds: Double) -> String {
        let s = max(0, Int(seconds))
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, (s / 60) % 60, s % 60) : String(format: "%d:%02d", s / 60, s % 60)
    }
    @MainActor static func language(_ code: String) -> String {
        AppStore.languages.first { $0.0 == code }?.1 ?? "Detect language"
    }
    static func noteTitle(_ date: Date = Date()) -> String {
        "Note, " + date.formatted(.dateTime.day().month(.abbreviated).year()) + ", " + date.formatted(date: .omitted, time: .shortened)
    }
    static func hotkeyName(_ key: HotkeyChoice) -> String {
        switch key {
        case .fn: "fn"
        case .rightOption: "right Option"
        case .rightCommand: "right Command"
        case .rightControl: "right Control"
        }
    }
    static func dictationHint(_ key: HotkeyChoice, _ mode: DictationMode) -> String {
        let name = hotkeyName(key)
        switch mode {
        case .hold: return "Hold \(name)"
        case .toggle: return "Press \(name)"
        case .holdOrDoubleTap: return "Hold or double-tap \(name)"
        }
    }
}

/// A title that becomes a text field when clicked. Return or clicking elsewhere saves; Escape cancels.
struct EditableTitle: View {
    let text: String
    var placeholder = ""
    var enabled = true
    @Binding var editing: Bool
    let onCommit: (String) -> Void
    @State private var draft = ""
    @State private var hovering = false
    @FocusState private var focused: Bool

    var body: some View {
        if editing {
            TextField(placeholder, text: $draft)
                .textFieldStyle(.plain).focused($focused)
                .onSubmit(commit)
                .onExitCommand { editing = false }
                .onChange(of: focused) { _, isFocused in if !isFocused, editing { commit() } }
                .onAppear { draft = text; focused = true }
                .accessibilityLabel("Note name")
        } else {
            HStack(spacing: 7) {
                Text(text.isEmpty ? placeholder : text).lineLimit(1)
                if enabled {
                    Image(systemName: "pencil").font(.system(size: 11)).foregroundStyle(LivePalette.secondary)
                        .opacity(hovering ? 1 : 0).accessibilityHidden(true)
                }
            }
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
            .onTapGesture { if enabled { editing = true } }
            .help(enabled ? "Click to rename" : "")
            .accessibilityAddTraits(enabled ? .isButton : [])
            .accessibilityHint(enabled ? "Rename" : "")
            .accessibilityAction { if enabled { editing = true } }
        }
    }

    private func commit() {
        guard editing else { return }
        editing = false
        let name = draft.components(separatedBy: .newlines).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        if !name.isEmpty, name != text { onCommit(name) }
    }
}

enum LiveNote {
    static func isActive(_ state: NoteRecorder.State) -> Bool {
        switch state {
        case .starting, .recording, .paused, .finishing: true
        case .idle, .failed: false
        }
    }
    @MainActor static func start(_ recorder: NoteRecorder, _ sources: NoteSources) {
        guard !isActive(recorder.state) else { return }
        recorder.title = LiveFormat.noteTitle()
        recorder.requestStart(sources)
    }
    static func symbol(_ sources: NoteSources) -> String {
        switch sources {
        case .microphone: "mic"
        case .systemAudio: "speaker.wave.2"
        case .both: "person.2"
        }
    }
    static func shortLabel(_ sources: NoteSources) -> String {
        switch sources {
        case .microphone: "Microphone"
        case .systemAudio: "System audio"
        case .both: "Both"
        }
    }
}

enum SystemPanes {
    /// Keyboard settings, where "Press Globe key to" lives. Apple's own help uses the x-help-action URL.
    static func openKeyboard() {
        let urls = ["x-help-action://openPrefPane?bundleId=com.apple.Keyboard-Settings.extension",
                    "x-apple.systempreferences:com.apple.Keyboard-Settings.extension"]
        for string in urls {
            if let url = URL(string: string), NSWorkspace.shared.open(url) { return }
        }
    }
}

extension Permissions.Kind {
    var displayName: String {
        switch self {
        case .microphone: "Microphone"
        case .accessibility: "Accessibility"
        case .inputMonitoring: "Input Monitoring"
        case .systemAudio: "System audio"
        }
    }
    var purpose: String {
        switch self {
        case .microphone: "Hears you while you dictate, and records You in notes."
        case .accessibility: "Pastes dictation and reads or replaces selected text with Writing tools."
        case .inputMonitoring: "Notices the dictation key while other apps are in front."
        case .systemAudio: "Records Others in a call. macOS asks the first time a note uses it."
        }
    }
    var symbol: String {
        switch self {
        case .microphone: "mic"
        case .accessibility: "keyboard"
        case .inputMonitoring: "hand.tap"
        case .systemAudio: "speaker.wave.2"
        }
    }
}

/// One permission with status dot, explanation and the right action.
struct LivePermissionRow: View {
    @EnvironmentObject private var permissions: Permissions
    let kind: Permissions.Kind
    var body: some View {
        let status = permissions.status[kind] ?? .unknown
        HStack(alignment: .center, spacing: 14) {
            Image(systemName: kind.symbol).font(.system(size: 14)).foregroundStyle(LivePalette.secondary).frame(width: 20)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 7) {
                    Text(kind.displayName).font(.system(size: 13, weight: .medium))
                    Circle().fill(color(status)).frame(width: 6, height: 6)
                    Text(label(status)).font(.system(size: 11)).foregroundStyle(status == .denied ? Color.red : LivePalette.secondary)
                }
                Text(kind.purpose).font(.system(size: 11)).foregroundStyle(LivePalette.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            switch status {
            case .granted:
                Button("Open Settings") { permissions.openSettings(kind) }.buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(LivePalette.secondary)
            case .denied:
                Button("Open Settings") { permissions.openSettings(kind) }.buttonStyle(LiveQuietButton())
            case .unknown:
                Button(kind == .systemAudio ? "Open Settings" : "Allow") { permissions.request(kind) }.buttonStyle(LiveQuietButton())
            }
        }.padding(.vertical, 12)
    }
    private func color(_ status: Permissions.Status) -> Color {
        switch status {
        case .granted: LivePalette.green
        case .denied: .red
        case .unknown: LivePalette.secondary
        }
    }
    private func label(_ status: Permissions.Status) -> String {
        switch status {
        case .granted: "Allowed"
        case .denied: "Not allowed"
        case .unknown: kind == .systemAudio ? "Asked on first use" : "Not set"
        }
    }
}

/// Explains the macOS Globe key setting that fights fn push-to-talk.
struct LiveFnHint: View {
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "globe").foregroundStyle(LivePalette.green).padding(.top, 1)
            VStack(alignment: .leading, spacing: 8) {
                Text("In System Settings, Keyboard, set \"Press \(Image(systemName: "globe")) key to\" to Do Nothing. Otherwise macOS also opens the emoji picker or Dictation when you hold fn.")
                    .font(.system(size: 11)).foregroundStyle(LivePalette.secondary).fixedSize(horizontal: false, vertical: true)
                Button("Open Keyboard Settings", action: SystemPanes.openKeyboard).buttonStyle(.plain).font(.system(size: 11, weight: .medium)).foregroundStyle(LivePalette.green)
            }
        }
        .padding(12).frame(maxWidth: .infinity, alignment: .leading)
        .background(LivePalette.selected.opacity(0.6), in: RoundedRectangle(cornerRadius: 8))
    }
}
