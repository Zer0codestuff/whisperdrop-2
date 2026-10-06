import SwiftUI
import UniformTypeIdentifiers
import WhisperDropCore

private enum Palette {
    static let green = Color(red: 43 / 255, green: 214 / 255, blue: 107 / 255)
    static let secondary = Color(white: 0.65)
    static let line = Color(white: 0.165)
    static let selected = Color(red: 13 / 255, green: 32 / 255, blue: 20 / 255)
}

struct ContentView: View {
    @EnvironmentObject private var store: AppStore
    @EnvironmentObject private var recorder: NoteRecorder
    @EnvironmentObject private var permissions: Permissions
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var writing: WritingController
    @EnvironmentObject private var writingSettings: WritingSettings
    @AppStorage("guideDone") private var guideDone = false
    @State private var targeted = false
    @State private var renamingNote: TranscriptionJob?
    @State private var displayedRevision: UUID?
    var body: some View {
        HStack(spacing: 0) {
            sidebar.frame(width: 262)
            Rectangle().fill(Palette.line).frame(width: 1)
            if LiveNote.isActive(recorder.state) {
                LiveNoteView()
            } else if writing.editorVisible {
                WritingEditorView()
            } else {
                libraryColumn
            }
        }
        .frame(minWidth: 860, minHeight: 580)
        .background(Color.black)
        .tint(Palette.green)
        .onChange(of: store.selection) { displayedRevision = nil }
        .onChange(of: recorder.state) {
            if LiveNote.isActive(recorder.state) { writing.showLibrary() }
            if case .failed(let message) = recorder.state {
                store.error = message
                recorder.dismissFailure()
            }
        }
        .overlay {
            if targeted {
                RoundedRectangle(cornerRadius: 16).strokeBorder(Palette.green, lineWidth: 2)
                    .background(Palette.green.opacity(0.06)).padding(8).allowsHitTesting(false)
            }
        }
        .onDrop(of: [.fileURL], isTargeted: $targeted) { providers in
            for provider in providers {
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    guard let url else { return }
                    Task { @MainActor in store.addFiles([url]) }
                }
            }
            return !providers.isEmpty
        }
        .sheet(isPresented: $store.showLink) { LinkView().environmentObject(store) }
        .sheet(isPresented: $store.showDiagnostics) { diagnostics }
        .sheet(item: $renamingNote) { note in RenameNoteView(note: note).environmentObject(store) }
        .overlay {
            if !guideDone {
                ZStack {
                    Color.black.opacity(0.72)
                    GuideView()
                        .background(Color.black, in: RoundedRectangle(cornerRadius: 16))
                        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Palette.line))
                }
            }
        }
        .alert("WhisperDrop", isPresented: Binding(get: { store.error != nil }, set: { if !$0 { store.error = nil } })) {
            Button("OK") { store.error = nil }
        } message: { Text(store.error ?? "") }
        .alert("Check the note language", isPresented: $recorder.showLanguageReminder) {
            Button("Start recording") { recorder.confirmStart() }
            Button("Cancel", role: .cancel) { recorder.cancelStart() }
        } message: {
            Text("Language for this note: \(NoteLanguage.label(settings.noteLanguage)). If the lesson or meeting is in another language, choose it next to New note. That choice applies to this note only.")
        }
    }
    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Text("WhisperDrop").font(.system(size: 21, weight: .semibold, design: .rounded))
                Text("2").font(.system(size: 13, weight: .medium)).foregroundStyle(Palette.green)
            }.padding(.top, 46).padding(.horizontal, 24)
            HStack(spacing: 8) {
                Button { writing.showLibrary(); store.chooseFiles() } label: { Label("Add files", systemImage: "plus").frame(maxWidth: .infinity) }
                    .buttonStyle(QuietButton())
                Button { writing.showLibrary(); store.showLink = true } label: { Image(systemName: "link").frame(width: 24) }
                    .buttonStyle(QuietButton()).help("Add YouTube video or playlist")
                    .accessibilityLabel("Add YouTube link")
            }.padding(.horizontal, 20).padding(.top, 27)
            NewNoteButton().padding(.horizontal, 20).padding(.top, 8).disabled(store.movingSavedFiles)
            HStack {
                Button("Library", action: writing.showLibrary).buttonStyle(.plain).font(.system(size: 12, weight: .medium))
                Spacer()
                Text("\(store.jobs.count)").font(.system(size: 12)).monospacedDigit()
            }.foregroundStyle(Palette.secondary).padding(.horizontal, 24).padding(.top, 30).padding(.bottom, 12)
            ScrollView {
                LazyVStack(spacing: 5) {
                    ForEach(store.jobs) { job in
                        Button { writing.showLibrary(); store.selection = job.id } label: {
                            HStack(alignment: .top, spacing: 10) {
                                Image(systemName: sidebarSymbol(job)).font(.system(size: 15)).foregroundStyle(!writing.editorVisible && store.selection == job.id ? Palette.green : Palette.secondary).frame(width: 20).padding(.top, 2)
                                VStack(alignment: .leading, spacing: 6) {
                                    Text(job.title).font(.system(size: 13, weight: .medium)).lineLimit(2).multilineTextAlignment(.leading)
                                    HStack(spacing: 5) {
                                        if job.status == .completed { Image(systemName: "checkmark").foregroundStyle(Palette.green) }
                                        Text(job.status.label)
                                    }.font(.system(size: 11)).foregroundStyle(job.status == .failed ? Color.red : Palette.secondary)
                                }
                                Spacer(minLength: 0)
                            }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
                                .background(!writing.editorVisible && store.selection == job.id ? Palette.selected : Color.clear, in: RoundedRectangle(cornerRadius: 10))
                                .contentShape(Rectangle())
                        }.buttonStyle(.plain)
                            .contextMenu {
                                if job.resolvedKind == .note {
                                    Button("Rename…") { renamingNote = job }.disabled(!store.canRenameNote(job))
                                }
                                if job.status == .failed || job.status == .cancelled { Button("Try again") { store.retry(job.id) } }
                                Button("Remove from library", role: .destructive) { store.remove(job.id) }.disabled(job.status.isActive)
                            }
                    }
                }.padding(.horizontal, 12)
                if store.jobs.isEmpty {
                    Text("Your recordings will appear here.").font(.system(size: 12)).foregroundStyle(Palette.secondary).padding(.horizontal, 24).padding(.top, 8).frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            if store.importing {
                HStack {
                    Text("Loading YouTube…").font(.system(size: 12))
                    Spacer()
                    Button("Cancel", action: store.cancelImport).buttonStyle(.plain).foregroundStyle(Palette.green)
                }.padding(20)
            }
            VStack(alignment: .leading, spacing: 18) {
                Button {
                    writing.openEditor()
                } label: {
                    HStack { Image(systemName: "text.cursor"); Text("Writing tools"); Spacer() }
                        .padding(10).background(writing.editorVisible ? Palette.selected : Color.clear, in: RoundedRectangle(cornerRadius: 10))
                        .foregroundStyle(writing.editorVisible ? Palette.green : Color.white)
                }.buttonStyle(.plain).font(.system(size: 13)).disabled(LiveNote.isActive(recorder.state))
                OpenModelsButton {
                    HStack { Image(systemName: "square.stack.3d.up"); Text("Models"); Spacer(); Text(settings.model.name).foregroundStyle(Palette.secondary) }
                        .contentShape(Rectangle())
                }.buttonStyle(.plain).font(.system(size: 13)).help("Choose and download models in Settings")
                SettingsLink {
                    HStack { Image(systemName: "gearshape"); Text("Settings"); Spacer() }
                }.buttonStyle(.plain).font(.system(size: 13)).help("Open settings")
                HStack(spacing: 7) {
                    Circle().fill(Palette.green).frame(width: 5, height: 5)
                    Text("Transcription stays on this Mac").font(.system(size: 10.5)).foregroundStyle(Palette.secondary)
                }
            }.padding(24)
        }.background(Color(white: 0.035))
    }
    private var libraryColumn: some View {
        VStack(spacing: 0) {
            header
            Rectangle().fill(Palette.line).frame(height: 1)
            ZStack {
                Color.black
                if let job = store.current { detail(job) } else { emptyState }
            }
            controls.padding(.horizontal, 28).padding(.bottom, 24).padding(.top, 12)
        }
    }
    private func sidebarSymbol(_ job: TranscriptionJob) -> String {
        switch job.resolvedKind {
        case .note: "person.2.wave.2"
        case .youtube: "play.rectangle"
        case .file: "waveform"
        }
    }
    private var header: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 5) {
                Text(store.current?.title ?? "Transcribe").font(.system(size: 17, weight: .semibold)).lineLimit(1)
                Text(store.current.map(sourceLabel) ?? "Audio and video, in your own words.")
                    .font(.system(size: 11)).foregroundStyle(Palette.secondary).lineLimit(1)
            }
            Spacer(minLength: 8)
            if let job = store.current, job.resolvedKind == .note {
                Button("Rename…") { renamingNote = job }
                    .buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(Palette.secondary)
                    .disabled(!store.canRenameNote(job))
            }
            if store.current?.status == .completed {
                if let job = store.current {
                    Menu {
                        Button("Review transcript…") { writing.openTranscript(job) }
                        Divider()
                        ForEach(writingSettings.actions) { action in
                            Button(action.title) { writing.openTranscript(job, actionID: action.id) }
                        }
                    } label: { Label("Writing", systemImage: "text.cursor") }
                        .menuStyle(.borderlessButton).fixedSize().disabled(writing.busy || store.transcriptText(job).isEmpty)
                }
                if let job = store.current, job.resolvedKind == .note, let audio = job.audioFile {
                    Button { NSWorkspace.shared.activateFileViewerSelecting(NoteAudio.savedFiles(in: audio)) } label: {
                        Image(systemName: "waveform")
                    }.buttonStyle(.plain).help("Show saved audio in Finder").accessibilityLabel("Show saved audio")
                }
                Button(action: store.copyTranscript) { Image(systemName: "doc.on.doc") }.buttonStyle(.plain).help("Copy transcript").accessibilityLabel("Copy transcript")
                Menu {
                    Button("Plain text (.txt)") { store.export("txt") }
                    Button("SubRip subtitles (.srt)") { store.export("srt") }
                    Button("WebVTT subtitles (.vtt)") { store.export("vtt") }
                } label: { Label("Export", systemImage: "square.and.arrow.up") }.menuStyle(.borderlessButton).fixedSize()
            }
        }.padding(.horizontal, 32).frame(height: 96)
    }
    private var emptyState: some View {
        VStack(spacing: 0) {
            LiveWaveMark().frame(width: 84, height: 64).padding(.bottom, 27).accessibilityHidden(true)
            Text("Drop a recording.").font(.system(size: 30, weight: .medium)).tracking(-0.7)
            Text("Leave with the words.").font(.system(size: 30, weight: .medium)).tracking(-0.7).foregroundStyle(Palette.secondary).padding(.top, 3)
            Text("Audio, video or a YouTube link.").font(.system(size: 13)).foregroundStyle(Palette.secondary).padding(.top, 20)
            HStack(spacing: 18) {
                Button("Choose files", action: store.chooseFiles).buttonStyle(GreenButton())
                Button("Paste a link") { store.showLink = true }.buttonStyle(.plain).foregroundStyle(Palette.secondary)
            }.padding(.top, 28)
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    @ViewBuilder private func detail(_ job: TranscriptionJob) -> some View {
        if job.status == .completed {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    HStack {
                        if let versions = job.textRevisions, !versions.isEmpty {
                            Picker("Text version", selection: $displayedRevision) {
                                Text("Transcript").tag(nil as UUID?)
                                ForEach(versions) { version in Text(version.title).tag(version.id as UUID?) }
                            }.labelsHidden().frame(maxWidth: 260, alignment: .leading)
                        } else {
                            Text("Transcript").font(.system(size: 12, weight: .medium)).foregroundStyle(Palette.secondary)
                        }
                        Spacer()
                        if writing.processingNotes.contains(job.id) {
                            ProgressView().controlSize(.small)
                            Text("Summarizing…").font(.system(size: 11)).foregroundStyle(Palette.secondary)
                        } else {
                            Text(job.modelName ?? "Whisper").font(.system(size: 11)).foregroundStyle(Palette.secondary)
                        }
                    }.padding(.bottom, 8)
                    if let revision = job.textRevisions?.first(where: { $0.id == displayedRevision }) {
                        VStack(alignment: .leading, spacing: 16) {
                            HStack {
                                Text("\(revision.modelName) · \(revision.created.formatted(date: .abbreviated, time: .shortened))")
                                    .font(.system(size: 11)).foregroundStyle(Palette.secondary)
                                Spacer()
                                Button("Copy version") {
                                    NSPasteboard.general.prepareForNewContents(with: .currentHostOnly)
                                    NSPasteboard.general.setString(revision.text, forType: .string)
                                }.buttonStyle(LiveQuietButton())
                            }
                            Text(revision.text).font(.system(size: 16)).lineSpacing(7).textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    } else {
                    if job.segments.isEmpty {
                        Text("No speech was detected in this recording.").foregroundStyle(Palette.secondary)
                    }
                    if let warning = job.error, !job.segments.isEmpty {
                        Text(warning).font(.system(size: 12)).foregroundStyle(.orange)
                    }
                    ForEach(TranscriptOutput.paragraphs(job.segments)) { segment in
                        HStack(alignment: .firstTextBaseline, spacing: 22) {
                            Text(segment.timeLabel).font(.system(size: 11)).monospacedDigit().foregroundStyle(Palette.secondary).frame(width: 44, alignment: .leading)
                            if let speaker = segment.speaker {
                                Text(speaker.label).font(.system(size: 11, weight: .medium))
                                    .foregroundStyle(speaker == .you ? Palette.green : .white)
                                    .frame(width: 52, alignment: .leading)
                            }
                            Text(segment.text).font(.system(size: 16)).lineSpacing(7).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    }
                }.padding(36).frame(maxWidth: 900, alignment: .leading).frame(maxWidth: .infinity)
            }
        } else {
            VStack(spacing: 18) {
                Image(systemName: job.status == .failed ? "exclamationmark.circle" : job.status.isActive ? "waveform" : "doc.text")
                    .font(.system(size: 35, weight: .ultraLight)).foregroundStyle(job.status == .failed ? .red : Palette.green)
                Text(job.status.isActive ? store.status : job.status == .queued ? "Ready when you are." : job.status.label)
                    .font(.system(size: 24, weight: .medium))
                Text(job.error ?? (job.status == .queued ? "Check the language, then transcribe the queue." : job.status == .cancelled ? "You can queue this recording again." : "You can keep adding recordings while this one is processed."))
                    .font(.system(size: 13)).foregroundStyle(Palette.secondary).multilineTextAlignment(.center).frame(maxWidth: 390)
                if job.status == .transcribing {
                    ProgressView(value: store.progress).frame(width: 240)
                }
                if job.status == .failed || job.status == .cancelled {
                    Button("Queue again") { store.retry(job.id) }.buttonStyle(GreenButton())
                }
            }.padding(32).frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
    private var controls: some View {
        VStack(spacing: 12) {
            if store.downloadingModel != nil {
                HStack {
                    Text(store.status).font(.system(size: 11)).foregroundStyle(Palette.secondary)
                    ProgressView(value: store.modelProgress).frame(maxWidth: 160)
                    Text("\(Int(store.modelProgress * 100))%").font(.system(size: 11)).monospacedDigit()
                    Button("Cancel", action: store.cancelModelDownload).buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(Palette.green)
                }
            }
            HStack(spacing: 18) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Model").font(.system(size: 10)).foregroundStyle(Palette.secondary)
                    OpenModelsButton {
                        HStack(spacing: 5) {
                            Text(store.model.name).lineLimit(1)
                            if !store.downloaded.contains(store.model.id) { Text("· download").foregroundStyle(Palette.secondary) }
                            Image(systemName: "chevron.right").font(.system(size: 9)).foregroundStyle(Palette.secondary)
                        }.contentShape(Rectangle())
                    }.buttonStyle(.plain).font(.system(size: 13)).frame(minWidth: 112, alignment: .leading)
                    .help("The model is chosen in Settings, Models")
                }
                Rectangle().fill(Palette.line).frame(width: 1, height: 28)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Language").font(.system(size: 10)).foregroundStyle(Palette.secondary)
                    Menu {
                        ForEach(AppStore.languages, id: \.0) { language in
                            Button(language.1) { settings.spokenLanguage = language.0 }
                        }
                    } label: {
                        HStack { Text(LiveFormat.language(settings.spokenLanguage)); Spacer(); Image(systemName: "chevron.down").font(.system(size: 9)) }
                    }.menuStyle(.borderlessButton).menuIndicator(.hidden).frame(width: 135).disabled(store.busy)
                    .help("The language you speak. Used for files, dictation and notes.")
                }
                Spacer(minLength: 0)
                if store.busy {
                    Button(action: store.cancel) { Label("Stop", systemImage: "stop.fill") }.buttonStyle(QuietButton())
                } else {
                    Button(action: store.start) {
                        HStack(spacing: 8) { Text("Transcribe"); if store.queuedCount > 0 { Text("\(store.queuedCount)").opacity(0.6) }; Image(systemName: "arrow.right") }
                    }.buttonStyle(GreenButton()).disabled(store.queuedCount == 0 || store.downloadingModel != nil)
                }
            }.padding(16).modifier(ControlSurface())
        }
    }
    private func sourceLabel(_ job: TranscriptionJob) -> String {
        switch job.resolvedKind {
        case .note: "Note"
        case .youtube: "YouTube"
        case .file: job.source.lastPathComponent
        }
    }
    private var diagnostics: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack { Text("Activity").font(.title2); Spacer(); Button("Done") { store.showDiagnostics = false } }
            ScrollView { Text(store.diagnostics.isEmpty ? "No activity yet." : store.diagnostics).font(.system(size: 11, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
        }.padding(28).frame(width: 680, height: 460)
    }
}

private struct RenameNoteView: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @FocusState private var nameFocused: Bool
    @State private var name: String
    @State private var failure: String?
    let note: TranscriptionJob

    init(note: TranscriptionJob) {
        self.note = note
        _name = State(initialValue: note.title)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Rename note").font(.system(size: 20, weight: .semibold))
            TextField("Note name", text: $name).textFieldStyle(.roundedBorder)
                .accessibilityLabel("Note name").focused($nameFocused).onSubmit(save)
            if let failure { Text(failure).font(.system(size: 12)).foregroundStyle(.red) }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save", action: save).keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }.padding(28).frame(width: 420)
            .defaultFocus($nameFocused, true)
    }

    private func save() {
        do {
            try store.renameNote(note.id, to: name)
            dismiss()
        } catch { failure = "Could not rename the note: \(error.localizedDescription)" }
    }
}

private struct ControlSurface: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @ViewBuilder func body(content: Content) -> some View {
        if #available(macOS 26, *), !reduceTransparency {
            content.glassEffect(.regular, in: RoundedRectangle(cornerRadius: 18))
        } else {
            content.background(Color(white: 0.07), in: RoundedRectangle(cornerRadius: 18))
                .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(Palette.line))
        }
    }
}
private struct QuietButton: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size: 12, weight: .medium)).padding(.horizontal, 12).padding(.vertical, 10)
            .background(Color.white.opacity(configuration.isPressed ? 0.14 : 0.065), in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Palette.line))
    }
}
private struct GreenButton: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size: 12, weight: .semibold)).foregroundStyle(enabled ? .black : Palette.secondary)
            .padding(.horizontal, 18).padding(.vertical, 12)
            .background(enabled ? Palette.green.opacity(configuration.isPressed ? 0.75 : 1) : Color.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 9))
    }
}

private struct LinkView: View {
    @EnvironmentObject private var store: AppStore
    @State private var link = ""
    @FocusState private var focused: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            Text("Add from YouTube").font(.system(size: 24, weight: .medium))
            Text("Paste a video or playlist link. Audio is downloaded, then transcribed on your Mac.").font(.system(size: 13)).foregroundStyle(Palette.secondary)
            TextField("https://www.youtube.com/watch?v=…", text: $link).textFieldStyle(.roundedBorder).focused($focused).onSubmit { if MediaInput.youtubeURL(link) != nil { store.addYouTube(link) } }
            HStack { Spacer(); Button("Cancel") { store.showLink = false }.keyboardShortcut(.cancelAction); Button("Add to queue") { store.addYouTube(link) }.buttonStyle(GreenButton()).disabled(MediaInput.youtubeURL(link) == nil) }
        }.padding(32).frame(width: 470).onAppear { focused = true }
    }
}
