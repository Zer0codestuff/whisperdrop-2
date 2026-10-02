import SwiftUI
import Combine
import WhisperDropCore

/// Contract file. Live recording view shown in the main window detail area while NoteRecorder is active. Reads NoteRecorder from the environment.
/// Laid out as a full reading column (header, transcript, control group) to match ContentView.
struct LiveNoteView: View {
    @EnvironmentObject private var recorder: NoteRecorder
    @State private var confirmDiscard = false
    @State private var following = true
    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle().fill(LivePalette.line).frame(height: 1)
            if let warning = recorder.warning {
                Text(warning).font(.system(size: 12)).foregroundStyle(.orange)
                    .padding(.horizontal, 32).padding(.vertical, 12).frame(maxWidth: .infinity, alignment: .leading)
            }
            ZStack {
                Color.black
                if recorder.segments.isEmpty && recorder.livePreview.isEmpty { waiting } else { transcript }
            }
            controls.padding(.horizontal, 28).padding(.bottom, 24).padding(.top, 12)
        }
        .background(Color.black)
        .tint(LivePalette.green)
        .confirmationDialog("Discard this note?", isPresented: $confirmDiscard) {
            Button("Discard", role: .destructive) { recorder.discard() }
            Button("Keep recording", role: .cancel) {}
        } message: { Text("The recording and its transcript are deleted.") }
    }

    private var header: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 5) {
                TextField(LiveFormat.noteTitle(), text: $recorder.title)
                    .textFieldStyle(.plain).font(.system(size: 17, weight: .semibold)).lineLimit(1)
                HStack(spacing: 6) {
                    Image(systemName: LiveNote.symbol(recorder.sources))
                    Text(recorder.sources.label)
                    Text("· " + NoteLanguage.label(recorder.sessionLanguage))
                }.font(.system(size: 11)).foregroundStyle(LivePalette.secondary)
            }
            Spacer(minLength: 8)
            HStack(spacing: 8) {
                Circle().fill(stateColor).frame(width: 7, height: 7)
                Text(stateLabel).font(.system(size: 11)).foregroundStyle(isFailed ? Color.red : LivePalette.secondary)
            }
            Text(LiveFormat.clock(recorder.elapsed)).font(.system(size: 17, weight: .medium, design: .monospaced))
                .accessibilityLabel("Elapsed \(LiveFormat.clock(recorder.elapsed))")
        }.padding(.horizontal, 32).frame(height: 96)
    }

    private var waiting: some View {
        VStack(spacing: 16) {
            LiveLevelBars(level: max(recorder.micLevel, recorder.systemLevel), active: recorder.state == .recording, maxHeight: 28)
            Text(recorder.state == .starting ? "Starting…" : "Listening.").font(.system(size: 24, weight: .medium))
            Text(isFailed ? failure : "Text appears after a pause, or after about a minute of continuous speech.")
                .font(.system(size: 13)).foregroundStyle(isFailed ? Color.red : LivePalette.secondary)
                .multilineTextAlignment(.center).frame(maxWidth: 390)
        }.padding(32).frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var transcript: some View {
        GeometryReader { viewport in
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        HStack {
                            Text("Live transcript").font(.system(size: 12, weight: .medium)).foregroundStyle(LivePalette.secondary)
                            Spacer()
                            if recorder.pendingChunks > 1 {
                                HStack(spacing: 6) {
                                    ProgressView().controlSize(.mini)
                                    Text("Catching up… \(recorder.pendingChunks)").monospacedDigit()
                                }.font(.system(size: 11)).foregroundStyle(LivePalette.secondary)
                            }
                        }.padding(.bottom, 8)
                        ForEach(TranscriptOutput.paragraphs(recorder.segments)) { segment in
                            HStack(alignment: .firstTextBaseline, spacing: 14) {
                                Text(segment.timeLabel).font(.system(size: 11)).monospacedDigit().foregroundStyle(LivePalette.secondary).frame(width: 44, alignment: .leading)
                                if let speaker = segment.speaker {
                                    Text(speaker.label).font(.system(size: 11, weight: .medium))
                                        .foregroundStyle(speaker == .you ? LivePalette.green : .white).frame(width: 44, alignment: .leading)
                                }
                                Text(segment.text).font(.system(size: 16)).lineSpacing(7).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                            }.id(segment.id)
                        }
                        // Words heard since the last confirmed paragraph. Replaced by confirmed text as chunks finish.
                        ForEach(recorder.livePreview) { preview in
                            HStack(alignment: .firstTextBaseline, spacing: 14) {
                                Text("Live").font(.system(size: 11)).foregroundStyle(LivePalette.secondary).frame(width: 44, alignment: .leading)
                                if let speaker = preview.speaker {
                                    Text(speaker.label).font(.system(size: 11, weight: .medium))
                                        .foregroundStyle(LivePalette.secondary).frame(width: 44, alignment: .leading)
                                }
                                Text(preview.text).font(.system(size: 16)).lineSpacing(7).foregroundStyle(LivePalette.secondary)
                                    .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                            }.accessibilityLabel("Unconfirmed: \(preview.text)")
                        }
                        Color.clear.frame(height: 1).id("bottom")
                            .background(GeometryReader { marker in
                                Color.clear.preference(key: LiveBottomEdge.self, value: marker.frame(in: .named("liveTranscript")).maxY)
                            })
                    }.padding(36).frame(maxWidth: 900, alignment: .leading).frame(maxWidth: .infinity)
                }
                .coordinateSpace(name: "liveTranscript")
                .onPreferenceChange(LiveBottomEdge.self) { edge in
                    // Follow new text only while the end is in view, so earlier text can be read while recording.
                    following = edge <= viewport.size.height + 80
                }
                .onAppear { proxy.scrollTo("bottom", anchor: .bottom) }
                .onChange(of: recorder.segments.count) { followNewText(proxy) }
                .onChange(of: recorder.livePreview) { followNewText(proxy) }
                .overlay(alignment: .bottomTrailing) {
                    if !following {
                        Button {
                            withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo("bottom", anchor: .bottom) }
                        } label: { Label("Latest", systemImage: "arrow.down") }
                            .buttonStyle(LiveQuietButton()).padding(20)
                            .help("Scroll to the newest words")
                    }
                }
            }
        }
    }

    private func followNewText(_ proxy: ScrollViewProxy) {
        guard following else { return }
        withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo("bottom", anchor: .bottom) }
    }

    private var controls: some View {
        HStack(spacing: 18) {
            if recorder.sources.usesMicrophone { meter("You", recorder.micLevel, LivePalette.green) }
            if recorder.sources.usesMicrophone && recorder.sources.usesSystemAudio {
                Rectangle().fill(LivePalette.line).frame(width: 1, height: 28)
            }
            if recorder.sources.usesSystemAudio { meter("Others", recorder.systemLevel, .white) }
            Spacer(minLength: 0)
            if recorder.state == .finishing {
                ProgressView().controlSize(.small)
                Text("Saving the note…").font(.system(size: 12)).foregroundStyle(LivePalette.secondary)
            } else {
                Button("Discard") { confirmDiscard = true }.buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(LivePalette.secondary)
                    .disabled(recorder.state != .recording && recorder.state != .starting)
                Button(action: recorder.stop) { Label("Stop and save", systemImage: "stop.fill") }
                    .buttonStyle(LiveGreenButton()).keyboardShortcut(.cancelAction)
                    .disabled(recorder.state != .recording)
            }
        }.padding(16).modifier(LiveControlSurface())
    }

    private func meter(_ label: String, _ level: Float, _ color: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.system(size: 10)).foregroundStyle(LivePalette.secondary)
            LiveLevelBars(level: level, active: recorder.state == .recording, color: color, maxHeight: 14)
        }.accessibilityElement().accessibilityLabel("\(label) level")
    }

    private var isFailed: Bool { if case .failed = recorder.state { true } else { false } }
    private var failure: String { if case .failed(let message) = recorder.state { message } else { "" } }
    private var stateColor: Color {
        switch recorder.state {
        case .recording: LivePalette.green
        case .starting, .finishing: LivePalette.green.opacity(0.45)
        case .failed: .red
        case .idle: LivePalette.secondary
        }
    }
    private var stateLabel: String {
        switch recorder.state {
        case .idle: "Stopped"
        case .starting: "Starting"
        case .recording: "Recording"
        case .finishing: "Saving"
        case .failed: "Failed"
        }
    }
}

private struct LiveBottomEdge: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

/// Sidebar control to start a new note with a chosen source. Reads NoteRecorder and AppSettings from the environment.
struct NewNoteButton: View {
    @EnvironmentObject private var recorder: NoteRecorder
    @EnvironmentObject private var settings: AppSettings
    var body: some View {
        let active = LiveNote.isActive(recorder.state)
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Text("Note language").foregroundStyle(LivePalette.secondary)
                Spacer(minLength: 0)
                Picker("Note language", selection: nextNoteLanguage) {
                    Text(LiveFormat.language(settings.spokenLanguage) + " (app)").tag("")
                    Divider()
                    ForEach(AppStore.languages, id: \.0) { Text($0.1).tag($0.0) }
                }.labelsHidden().frame(maxWidth: 136).disabled(active)
                .help("Another language for the next note only. The app language is set in Settings, General.")
            }.font(.system(size: 11))
            Menu {
                ForEach(NoteSources.allCases) { source in
                    Button { LiveNote.start(recorder, source) } label: {
                        Label(source.label + (source == settings.noteSources ? " (default)" : ""), systemImage: LiveNote.symbol(source))
                    }
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: active ? "record.circle.fill" : "record.circle").foregroundStyle(active ? LivePalette.green : .white)
                    Text(active ? "Recording" : "New note")
                }.frame(maxWidth: .infinity)
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden)
            .font(.system(size: 12, weight: .medium))
            .padding(.horizontal, 12).padding(.vertical, 10)
            .background(Color.white.opacity(0.065), in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(LivePalette.line))
            .disabled(active)
            .help(active ? "A note is recording" : "Record a call, lecture or meeting")
            Toggle("Keep audio", isOn: $settings.keepNoteAudio)
                .toggleStyle(.checkbox).font(.system(size: 11)).foregroundStyle(LivePalette.secondary)
                .disabled(active)
        }
    }
    private var nextNoteLanguage: Binding<String> {
        Binding(get: { settings.nextNoteLanguage ?? "" }, set: { settings.nextNoteLanguage = $0.isEmpty ? nil : $0 })
    }
}
