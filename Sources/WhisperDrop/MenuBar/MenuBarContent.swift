import SwiftUI
import AppKit
import WhisperDropCore

/// Contract file. Content of the MenuBarExtra (window style). Reads AppStore, AppSettings, ModelHost, DictationController and NoteRecorder from the environment.
struct MenuBarContent: View {
    @EnvironmentObject private var store: AppStore
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var host: ModelHost
    @EnvironmentObject private var dictation: DictationController
    @EnvironmentObject private var recorder: NoteRecorder
    @EnvironmentObject private var writing: WritingController
    @EnvironmentObject private var writingSettings: WritingSettings
    @Environment(\.openWindow) private var openWindow
    @State private var panel: NSWindow?
    @State private var confirmDiscard = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            status.padding(.horizontal, 10).padding(.top, 4).padding(.bottom, 8)
            HStack {
                Text("Keep model ready").font(.system(size: 13))
                Spacer()
                Toggle("", isOn: $settings.keepReady).toggleStyle(.switch).controlSize(.mini).labelsHidden()
            }.padding(.horizontal, 10).padding(.vertical, 4)
            HStack {
                Text("Language").font(.system(size: 13))
                Spacer()
                Picker("Language", selection: $settings.spokenLanguage) {
                    ForEach(AppStore.languages, id: \.0) { Text($0.1).tag($0.0) }
                }.labelsHidden().controlSize(.small).fixedSize()
            }.padding(.horizontal, 10).padding(.vertical, 4)
            .help("The language you speak. Used for files, dictation and notes.")
            separator
            dictationRows
            separator
            if LiveNote.isActive(recorder.state) { noteCard } else { newNoteRows }
            separator
            Button { close(); writing.openEditor(); openMain() } label: {
                MenuRowLabel(title: "Writing tools", subtitle: "Revise text locally", symbol: "text.cursor")
            }.buttonStyle(MenuRowStyle())
            Button {
                close()
                if let text = dictation.recent.first { writing.openServiceText(text) }
            } label: { MenuRowLabel(title: "Improve last dictation", symbol: "text.bubble") }
                .buttonStyle(MenuRowStyle()).disabled(dictation.recent.isEmpty)
            separator
            Button { close(); openMain() } label: { MenuRowLabel(title: "Open WhisperDrop 2", symbol: "macwindow") }
                .buttonStyle(MenuRowStyle())
            SettingsLink { MenuRowLabel(title: "Settings…", symbol: "gearshape", shortcut: "⌘,") }
                .buttonStyle(MenuRowStyle())
                .simultaneousGesture(TapGesture().onEnded { NSApp.activate(ignoringOtherApps: true); close() })
            separator
            Button { NSApp.terminate(nil) } label: { MenuRowLabel(title: "Quit WhisperDrop 2", symbol: "power", shortcut: "⌘Q") }
                .buttonStyle(MenuRowStyle()).keyboardShortcut("q")
        }
        .padding(6).frame(width: 290)
        .background(Color.black)
        .background(WindowReader(window: $panel))
        .preferredColorScheme(.dark)
        .tint(LivePalette.green)
        .onChange(of: settings.residency) { _, value in
            host.residency = value
            host.keepReady = settings.keepReady
            if settings.keepReady { LiveModels.prewarm(settings: settings, store: store, host: host) }
        }
    }

    private var separator: some View { Rectangle().fill(LivePalette.line).frame(height: 1).padding(.horizontal, 10).padding(.vertical, 5) }

    // MARK: Status line

    private var status: some View {
        let (text, color, clock) = statusLine
        return HStack(spacing: 8) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(text).font(.system(size: 12, weight: .medium)).foregroundStyle(color == .red ? Color.red : Color.white).lineLimit(1)
            Spacer(minLength: 8)
            if let clock { Text(clock).font(.system(size: 12, design: .monospaced)).foregroundStyle(LivePalette.secondary) }
        }
    }
    private var statusLine: (String, Color, String?) {
        switch recorder.state {
        case .starting: return ("Starting note", LivePalette.green, nil)
        case .recording: return ("Recording note", LivePalette.green, LiveFormat.clock(recorder.elapsed))
        case .finishing: return ("Saving note", LivePalette.green, LiveFormat.clock(recorder.elapsed))
        case .failed(let message): return (message, .red, nil)
        case .idle: break
        }
        switch dictation.state {
        case .listening: return ("Listening", LivePalette.green, nil)
        case .transcribing: return ("Transcribing", LivePalette.green, nil)
        case .failed(let message): return (message, .red, nil)
        case .idle: break
        }
        if store.busy { return ("Transcribing a file", LivePalette.green, nil) }
        switch host.state {
        case .unloaded: return ("Model unloaded", LivePalette.secondary, nil)
        case .loading: return ("Model loading", LivePalette.green.opacity(0.45), nil)
        case .ready: return ("Model ready", LivePalette.green, nil)
        case .busy: return ("Transcribing", LivePalette.green, nil)
        case .failed(let message): return (message, .red, nil)
        }
    }

    // MARK: Dictation

    @ViewBuilder private var dictationRows: some View {
        let noteActive = LiveNote.isActive(recorder.state)
        let listening = if case .listening = dictation.state { true } else { false }
        let hint = noteActive ? "Finish the note first" : settings.dictationEnabled ? LiveFormat.dictationHint(settings.hotkey, settings.dictationMode) : "Shortcut is off in Settings"
        Button { dictation.toggle() } label: {
            MenuRowLabel(title: listening ? "Stop dictation" : dictation.state == .transcribing ? "Transcribing" : "Start dictation",
                         subtitle: hint, symbol: listening ? "stop.circle" : "mic", accent: listening)
        }
        .buttonStyle(MenuRowStyle())
        .disabled(noteActive || dictation.state == .transcribing)
        Button { dictation.copyLast(); close() } label: {
            MenuRowLabel(title: "Copy last dictation", subtitle: dictation.recent.first.map(preview), symbol: "doc.on.doc")
        }
        .buttonStyle(MenuRowStyle())
        .disabled(dictation.recent.isEmpty)
    }
    private func preview(_ text: String) -> String {
        let flat = text.replacingOccurrences(of: "\n", with: " ")
        return flat.count > 38 ? String(flat.prefix(38)) + "…" : flat
    }

    // MARK: Notes

    @ViewBuilder private var newNoteRows: some View {
        Text("New note").font(.system(size: 11, weight: .medium)).foregroundStyle(LivePalette.secondary)
            .padding(.horizontal, 10).padding(.top, 2).padding(.bottom, 4)
        if let language = settings.nextNoteLanguage {
            Text("Next note: \(LiveFormat.language(language))").font(.system(size: 11)).foregroundStyle(LivePalette.green)
                .padding(.horizontal, 10).padding(.bottom, 2)
        }
        ForEach(NoteSources.allCases) { source in
            Button { LiveNote.start(recorder, source); openMain() } label: {
                MenuRowLabel(title: source.label, subtitle: source == settings.noteSources ? "Default" : nil, symbol: LiveNote.symbol(source))
            }
            .buttonStyle(MenuRowStyle())
            .disabled(store.busy || recorder.state == .finishing)
        }
        if store.busy {
            Text("A file is transcribing").font(.system(size: 11)).foregroundStyle(LivePalette.secondary).padding(.horizontal, 36).padding(.top, 2)
        }
    }

    private var noteCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: LiveNote.symbol(recorder.sources)).foregroundStyle(LivePalette.green).frame(width: 16)
                VStack(alignment: .leading, spacing: 2) {
                    Text(recorder.title.isEmpty ? "Note" : recorder.title).font(.system(size: 13, weight: .medium)).lineLimit(1)
                    Text(recorder.sources.label).font(.system(size: 11)).foregroundStyle(LivePalette.secondary)
                }
                Spacer(minLength: 8)
                Text(LiveFormat.clock(recorder.elapsed)).font(.system(size: 15, weight: .medium, design: .monospaced))
            }
            HStack(spacing: 14) {
                if recorder.sources.usesMicrophone { meter("You", recorder.micLevel) }
                if recorder.sources.usesSystemAudio { meter("Others", recorder.systemLevel) }
                Spacer()
                if recorder.pendingChunks > 1 {
                    Text("Catching up…").font(.system(size: 11)).foregroundStyle(LivePalette.secondary)
                }
            }
            if recorder.state == .finishing {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Transcribing the last words").font(.system(size: 11)).foregroundStyle(LivePalette.secondary)
                }
            } else {
                HStack(spacing: 8) {
                    Button(confirmDiscard ? "Discard note" : "Discard") {
                        if confirmDiscard { recorder.discard(); confirmDiscard = false } else { armDiscard() }
                    }
                    .buttonStyle(LiveQuietButton()).foregroundStyle(confirmDiscard ? Color.red : Color.white)
                    Spacer()
                    Button("Stop and save") { confirmDiscard = false; recorder.stop() }.buttonStyle(LiveGreenButton())
                        .disabled(recorder.state != .recording)
                }
            }
        }
        .padding(12)
        .background(LivePalette.selected.opacity(0.7), in: RoundedRectangle(cornerRadius: 10))
        .padding(.horizontal, 4).padding(.vertical, 2)
    }
    private func meter(_ label: String, _ level: Float) -> some View {
        HStack(spacing: 6) {
            Text(label).font(.system(size: 11, weight: .medium)).foregroundStyle(label == "You" ? LivePalette.green : .white)
            LiveLevelBars(level: level, active: recorder.state == .recording, maxHeight: 12)
        }
    }
    private func armDiscard() {
        confirmDiscard = true
        Task { try? await Task.sleep(for: .seconds(3)); confirmDiscard = false }
    }

    // MARK: Window

    private func openMain() {
        openWindow(id: "main")
        NSApp.activate(ignoringOtherApps: true)
    }
    private func close() { panel?.close() }
}

/// Menu bar icon reflecting dictation and recording state.
struct MenuBarLabel: View {
    @EnvironmentObject private var dictation: DictationController
    @EnvironmentObject private var recorder: NoteRecorder
    var body: some View {
        if LiveNote.isActive(recorder.state) {
            HStack(spacing: 4) {
                Image(nsImage: Self.recordIcon)
                Text(LiveFormat.clock(recorder.elapsed)).monospacedDigit()
            }
        } else {
            switch dictation.state {
            case .listening: Image(systemName: "waveform.circle.fill")
            case .transcribing: Image(systemName: "ellipsis.circle")
            case .failed: Image(systemName: "exclamationmark.triangle")
            case .idle: Image(systemName: "waveform")
            }
        }
    }
    /// Non-template so the recording dot keeps the brand green in the menu bar.
    private static let recordIcon: NSImage = {
        let config = NSImage.SymbolConfiguration(pointSize: 13, weight: .regular)
            .applying(.init(paletteColors: [NSColor(red: 43 / 255, green: 214 / 255, blue: 107 / 255, alpha: 1)]))
        let image = NSImage(systemSymbolName: "record.circle.fill", accessibilityDescription: "Recording note")?
            .withSymbolConfiguration(config) ?? NSImage()
        image.isTemplate = false
        return image
    }()
}

// MARK: Menu rows

private struct MenuRowLabel: View {
    let title: String
    var subtitle: String?
    let symbol: String
    var shortcut: String?
    var accent = false
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol).font(.system(size: 13)).frame(width: 16)
                .foregroundStyle(accent ? LivePalette.green : LivePalette.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 13))
                if let subtitle { Text(subtitle).font(.system(size: 11)).foregroundStyle(LivePalette.secondary).lineLimit(1) }
            }
            Spacer(minLength: 8)
            if let shortcut { Text(shortcut).font(.system(size: 12)).foregroundStyle(LivePalette.secondary) }
        }
    }
}

private struct MenuRowStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { Row(configuration: configuration) }
    private struct Row: View {
        let configuration: ButtonStyleConfiguration
        @Environment(\.isEnabled) private var enabled
        @State private var hovering = false
        var body: some View {
            configuration.label
                .padding(.horizontal, 10).padding(.vertical, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(fill, in: RoundedRectangle(cornerRadius: 6))
                .contentShape(Rectangle())
                .opacity(enabled ? 1 : 0.4)
                .onHover { hovering = $0 }
        }
        private var fill: Color {
            guard enabled else { return .clear }
            if configuration.isPressed { return Color.white.opacity(0.14) }
            return hovering ? Color.white.opacity(0.08) : .clear
        }
    }
}

/// Captures the hosting window so actions can close the menu bar panel.
private struct WindowReader: NSViewRepresentable {
    @Binding var window: NSWindow?
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { window = view.window }
        return view
    }
    func updateNSView(_ nsView: NSView, context: Context) {
        if nsView.window !== window { DispatchQueue.main.async { window = nsView.window } }
    }
}
