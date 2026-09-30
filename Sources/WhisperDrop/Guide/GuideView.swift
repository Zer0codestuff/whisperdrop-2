import SwiftUI
import AppKit
import WhisperDropCore

/// First-launch guide shown over the main window. Reads AppStore, AppSettings and Permissions from the environment.
/// Done stores `guideDone = true`; Help and Settings, Permissions clear it to show the guide again.
struct GuideView: View {
    private enum Step: Int, CaseIterable { case welcome, setup, dictation, notes, files, permissions }
    @EnvironmentObject private var store: AppStore
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var permissions: Permissions
    @AppStorage("guideDone") private var guideDone = false
    @State private var step = Step.welcome
    private let poll = Timer.publish(every: 1.5, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Text("WhisperDrop").font(.system(size: 15, weight: .semibold, design: .rounded))
                Text("2").font(.system(size: 11, weight: .medium)).foregroundStyle(LivePalette.green)
                Spacer()
                Text("\(step.rawValue + 1) of \(Step.allCases.count)").font(.system(size: 11)).monospacedDigit()
                    .foregroundStyle(LivePalette.secondary)
            }.padding(.bottom, 26)
            Group {
                switch step {
                case .welcome: welcome
                case .setup: setup
                case .dictation: dictation
                case .notes: notes
                case .files: files
                case .permissions: access
                }
            }
            .id(step)
            .transition(.opacity)
            Spacer(minLength: 16)
            footer
        }
        .padding(32).frame(width: 580, height: 580)
        .background(Color.black)
        .preferredColorScheme(.dark)
        .tint(LivePalette.green)
        .onAppear { permissions.refresh() }
        .onReceive(poll) { _ in if step == .permissions { permissions.refresh() } }
    }

    // MARK: Steps

    private var welcome: some View {
        VStack(alignment: .leading, spacing: 0) {
            LiveWaveMark(scale: 0.6).padding(.bottom, 22).accessibilityHidden(true)
            heading("Speech to text, on this Mac.",
                    "WhisperDrop 2 transcribes with a Whisper model that runs locally. Nothing is uploaded, and once a model is downloaded it works offline.")
            GuideRow(symbol: "mic", title: "Dictation", detail: "Hold a key, talk, and the text appears where your cursor is.", divider: false)
            GuideRow(symbol: "person.2.wave.2", title: "Notes", detail: "Record a lecture, call or meeting. The transcript builds while you listen.")
            GuideRow(symbol: "waveform", title: "Files and YouTube", detail: "Drop audio or video, or paste a link, and get a transcript you can export.")
        }
    }

    private var setup: some View {
        let model = settings.model
        return VStack(alignment: .leading, spacing: 0) {
            heading("Two choices before you start.",
                    "The model does the listening. The language tells it what to expect, so choose the one you speak.")
            GuideRow(symbol: "square.stack.3d.up", title: "\(model.name) model", detail: "\(model.detail) \(model.size), downloaded once.", divider: false) {
                if store.downloadingModel == model.id {
                    HStack(spacing: 8) {
                        ProgressView(value: store.modelProgress).frame(width: 80)
                        Text("\(Int(store.modelProgress * 100))%").font(.system(size: 11)).monospacedDigit().foregroundStyle(LivePalette.secondary)
                    }
                } else if store.downloaded.contains(model.id) {
                    Label("Ready", systemImage: "checkmark.circle.fill").font(.system(size: 12)).foregroundStyle(LivePalette.green)
                } else {
                    Button("Download") { store.downloadModel(model) }.buttonStyle(LiveQuietButton())
                        .disabled(store.downloadingModel != nil || store.busy)
                }
            }
            GuideRow(symbol: "globe", title: "Spoken language", detail: "Used for files, dictation and notes. Detect language guesses from the first seconds and can choose the wrong one.") {
                Picker("Spoken language", selection: $settings.spokenLanguage) {
                    ForEach(AppStore.languages, id: \.0) { Text($0.1).tag($0.0) }
                }.labelsHidden().frame(width: 150)
            }
            note("Other models are in Models, in the sidebar. The language is also in the menu bar and in Settings, General.")
        }
    }

    private var dictation: some View {
        let key = LiveFormat.hotkeyName(settings.hotkey)
        return VStack(alignment: .leading, spacing: 0) {
            heading("Dictate into any app.",
                    "Put the cursor where the text should go, then talk. WhisperDrop types what you said when you finish.")
            switch settings.dictationMode {
            case .holdOrDoubleTap:
                GuideRow(symbol: "hand.point.down", title: "Hold \(key)", detail: "Talk while you hold it. Let go to insert the text.", divider: false)
                GuideRow(symbol: "hand.tap", title: "Double-tap \(key)", detail: "Hands-free. Press \(key) once more to stop.")
            case .hold:
                GuideRow(symbol: "hand.point.down", title: "Hold \(key)", detail: "Talk while you hold it. Let go to insert the text.", divider: false)
            case .toggle:
                GuideRow(symbol: "hand.tap", title: "Press \(key)", detail: "Press once to start and again to stop.", divider: false)
            }
            GuideRow(symbol: "textformat.abc", title: "Names and terms", detail: "Add them under Vocabulary in Settings, Dictation. The key and mode can be changed there too.")
            if settings.hotkey == .fn { LiveFnHint().padding(.top, 12) }
        }
    }

    private var notes: some View {
        VStack(alignment: .leading, spacing: 0) {
            heading("Record a lecture or a meeting.",
                    "Choose New note in the sidebar or the menu bar. Text appears while you record, and the note is saved when you stop.")
            GuideRow(symbol: "mic", title: "You", detail: "Your microphone.", divider: false)
            GuideRow(symbol: "speaker.wave.2", title: "Others", detail: "Sound from other apps, such as a video call or a recorded lesson.")
            GuideRow(symbol: "globe", title: "A different language once", detail: "Note language, beside New note, applies to the next note only. Then the app language returns.")
            GuideRow(symbol: "waveform", title: "Keep audio", detail: "Saves the recording next to its transcript. When off, the audio is deleted after saving.")
        }
    }

    private var files: some View {
        VStack(alignment: .leading, spacing: 0) {
            heading("Transcribe files and videos.",
                    "Drop audio or video on the window, or paste a YouTube video or playlist link. Then press Transcribe.")
            GuideRow(symbol: "square.and.arrow.up", title: "Copy or export", detail: "Plain text, or SRT and VTT subtitles with timings.", divider: false)
            GuideRow(symbol: "folder", title: "Saved files", detail: "Audio and transcripts are kept in \(savedFolder). You can choose another folder in Settings, General.")
            GuideRow(symbol: "memorychip", title: "Memory", detail: "The model unloads when idle to free memory. Keep model ready, in the menu bar, keeps it loaded.")
        }
    }

    private var access: some View {
        VStack(alignment: .leading, spacing: 0) {
            heading("Allow what you need.",
                    "macOS asks once for each permission. Skip any of them and allow it later in Settings, Permissions.")
            ForEach(Array(Permissions.Kind.allCases.enumerated()), id: \.element) { index, kind in
                if index > 0 { Rectangle().fill(LivePalette.line).frame(height: 1) }
                LivePermissionRow(kind: kind)
            }
        }
    }

    // MARK: Parts

    private func heading(_ title: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.system(size: 24, weight: .medium)).tracking(-0.5).fixedSize(horizontal: false, vertical: true)
            Text(detail).font(.system(size: 13)).foregroundStyle(LivePalette.secondary).fixedSize(horizontal: false, vertical: true)
        }.padding(.bottom, 20)
    }

    private func note(_ text: String) -> some View {
        Text(text).font(.system(size: 11)).foregroundStyle(LivePalette.secondary).fixedSize(horizontal: false, vertical: true).padding(.top, 14)
    }

    private var savedFolder: String { (store.savedFolder.path as NSString).abbreviatingWithTildeInPath }

    private var footer: some View {
        HStack(spacing: 14) {
            HStack(spacing: 6) {
                ForEach(Step.allCases, id: \.self) { item in
                    Capsule().fill(item == step ? LivePalette.green : LivePalette.line)
                        .frame(width: item == step ? 16 : 6, height: 6)
                }
            }.accessibilityHidden(true)
            Spacer()
            if step != .permissions {
                Button("Skip") { guideDone = true }.buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(LivePalette.secondary)
            }
            if let previous = Step(rawValue: step.rawValue - 1) {
                Button("Back") { go(previous) }.buttonStyle(LiveQuietButton())
            }
            if let next = Step(rawValue: step.rawValue + 1) {
                Button("Next") { go(next) }.buttonStyle(LiveGreenButton()).keyboardShortcut(.defaultAction)
            } else {
                Button("Start using WhisperDrop") { guideDone = true }.buttonStyle(LiveGreenButton()).keyboardShortcut(.defaultAction)
            }
        }
    }

    private func go(_ next: Step) {
        withAnimation(.easeOut(duration: 0.18)) { step = next }
    }
}

/// Icon, title and explanation with an optional control on the right, separated like Settings rows.
private struct GuideRow<Control: View>: View {
    let symbol: String
    let title: String
    let detail: String
    var divider = true
    @ViewBuilder var control: Control
    var body: some View {
        VStack(spacing: 0) {
            if divider { Rectangle().fill(LivePalette.line).frame(height: 1) }
            HStack(alignment: .center, spacing: 14) {
                Image(systemName: symbol).font(.system(size: 14)).foregroundStyle(LivePalette.green).frame(width: 20)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.system(size: 13, weight: .medium))
                    Text(detail).font(.system(size: 11)).foregroundStyle(LivePalette.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 12)
                control
            }.padding(.vertical, 12)
        }
    }
}

extension GuideRow where Control == EmptyView {
    init(symbol: String, title: String, detail: String, divider: Bool = true) {
        self.init(symbol: symbol, title: title, detail: detail, divider: divider) { EmptyView() }
    }
}

/// Help menu item that shows the guide again in the main window.
struct GuideMenuItem: View {
    @AppStorage private var guideDone: Bool
    @Environment(\.openWindow) private var openWindow
    init(defaults: UserDefaults) { _guideDone = AppStorage(wrappedValue: false, "guideDone", store: defaults) }
    var body: some View {
        Button("WhisperDrop 2 Guide") {
            guideDone = false
            openWindow(id: "main")
            NSApp.activate(ignoringOtherApps: true)
        }
    }
}
