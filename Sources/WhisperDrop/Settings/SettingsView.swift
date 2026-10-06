import SwiftUI
import Combine
import AppKit
import ServiceManagement
import WhisperDropCore

/// Contract file. Settings window content. Reads AppStore, AppSettings, ModelHost, DictationController and Permissions from the environment.
struct SettingsView: View {
    enum Tab: String, CaseIterable, Identifiable {
        case general = "General", models = "Models", dictation = "Dictation", notes = "Notes", writing = "Writing", permissions = "Permissions"
        var id: String { rawValue }
        var symbol: String {
            switch self {
            case .general: "gearshape"
            case .models: "square.stack.3d.up"
            case .dictation: "waveform"
            case .notes: "note.text"
            case .writing: "text.cursor"
            case .permissions: "lock.shield"
            }
        }
    }
    /// UserDefaults key of the selected pane, so other windows can open Settings on Models.
    static let tabKey = "settingsTab"
    @EnvironmentObject private var permissions: Permissions
    @AppStorage(SettingsView.tabKey) private var storedTab = Tab.general.rawValue
    private var tab: Tab { Tab(rawValue: storedTab) ?? .general }
    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text("WhisperDrop").font(.system(size: 15, weight: .semibold, design: .rounded))
                    Text("2").font(.system(size: 11, weight: .medium)).foregroundStyle(LivePalette.green)
                }.padding(.horizontal, 12).padding(.top, 40).padding(.bottom, 18)
                ForEach(Tab.allCases) { item in
                    Button { storedTab = item.rawValue } label: {
                        HStack(spacing: 9) {
                            Image(systemName: item.symbol).font(.system(size: 12)).frame(width: 16)
                                .foregroundStyle(tab == item ? LivePalette.green : LivePalette.secondary)
                            Text(item.rawValue).font(.system(size: 13))
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 12).padding(.vertical, 7)
                        .background(tab == item ? LivePalette.selected : Color.clear, in: RoundedRectangle(cornerRadius: 7))
                        .overlay(alignment: .leading) {
                            if tab == item { Capsule().fill(LivePalette.green).frame(width: 2, height: 14) }
                        }
                        .contentShape(Rectangle())
                    }.buttonStyle(.plain)
                }
                Spacer()
                HStack(spacing: 7) {
                    Circle().fill(LivePalette.green).frame(width: 5, height: 5)
                    Text("Everything stays on this Mac").font(.system(size: 10.5)).foregroundStyle(LivePalette.secondary)
                }.padding(12)
            }
            .padding(.horizontal, 10).padding(.bottom, 8)
            .frame(width: 168).frame(maxHeight: .infinity).background(LivePalette.sidebar)
            Rectangle().fill(LivePalette.line).frame(width: 1)
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    switch tab {
                    case .general: GeneralPane()
                    case .dictation: DictationPane()
                    case .models: ModelsPane()
                    case .notes: NotesPane()
                    case .writing: WritingSettingsPane()
                    case .permissions: PermissionsPane()
                    }
                }.padding(.horizontal, 32).padding(.top, 36).padding(.bottom, 28).frame(maxWidth: .infinity, alignment: .leading)
            }.background(Color.black)
        }
        .frame(width: 720, height: 560)
        .background(Color.black)
        .preferredColorScheme(.dark)
        .tint(LivePalette.green)
        .onAppear { permissions.refresh() }
    }
}

// MARK: Building blocks

private struct PaneHeader: View {
    let title: String
    let subtitle: String
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: 22, weight: .medium)).tracking(-0.3)
            Text(subtitle).font(.system(size: 12)).foregroundStyle(LivePalette.secondary).fixedSize(horizontal: false, vertical: true)
        }.padding(.bottom, 18)
    }
}

private struct SettingRow<Control: View>: View {
    let title: String
    var detail: String?
    var divider = true
    @ViewBuilder var control: Control
    var body: some View {
        VStack(spacing: 0) {
            if divider { Rectangle().fill(LivePalette.line).frame(height: 1) }
            HStack(alignment: .center, spacing: 16) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.system(size: 13))
                    if let detail {
                        Text(detail).font(.system(size: 11)).foregroundStyle(LivePalette.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 12)
                control
            }.padding(.vertical, 12)
        }
    }
}

private struct Switch: View {
    @Binding var isOn: Bool
    var body: some View { Toggle("", isOn: $isOn).toggleStyle(.switch).controlSize(.small).labelsHidden() }
}

private struct LanguagePicker: View {
    @Binding var code: String
    var body: some View {
        Picker("", selection: $code) {
            ForEach(AppStore.languages, id: \.0) { language in Text(language.1).tag(language.0) }
        }.pickerStyle(.menu).labelsHidden().frame(width: 190)
    }
}

// MARK: General

private struct GeneralPane: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var store: AppStore
    @EnvironmentObject private var recorder: NoteRecorder
    @EnvironmentObject private var updater: AppUpdater
    @State private var loginEnabled = SMAppService.mainApp.status == .enabled
    @State private var loginStatus = SMAppService.mainApp.status
    @State private var loginError: String?
    var body: some View {
        PaneHeader(title: "General", subtitle: "How WhisperDrop 2 sits on your Mac.")
        SettingRow(title: "Spoken language", detail: "Used for files, dictation and notes. Detect language guesses from the first seconds and can choose the wrong one.", divider: false) {
            LanguagePicker(code: $settings.spokenLanguage)
        }
        SettingRow(title: "Launch at login", detail: "Keeps dictation ready from the menu bar after you sign in.") {
            Switch(isOn: Binding(get: { loginEnabled }, set: setLogin))
        }
        if loginStatus == .requiresApproval {
            HStack(spacing: 8) {
                Text("Allow WhisperDrop 2 in Login Items to finish.").font(.system(size: 11)).foregroundStyle(LivePalette.secondary)
                Button("Open Login Items") { SMAppService.openSystemSettingsLoginItems() }.buttonStyle(.plain).font(.system(size: 11, weight: .medium)).foregroundStyle(LivePalette.green)
            }.padding(.bottom, 10)
        }
        if let loginError {
            Text(loginError).font(.system(size: 11)).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true).padding(.bottom, 10)
        }
        SettingRow(title: "Show in Dock", detail: "When off, WhisperDrop 2 lives in the menu bar only.") {
            Switch(isOn: $settings.showInDock)
        }
        .onChange(of: settings.showInDock) { _, show in
            NSApp.setActivationPolicy(show ? .regular : .accessory)
            NSApp.activate(ignoringOtherApps: true)
        }
        SettingRow(title: "Saved files", detail: "Audio and Transcripts are stored in this folder.") {
            HStack(spacing: 12) {
                Button("Show") { NSWorkspace.shared.open(store.savedFolder) }
                Button("Choose…", action: store.chooseSavedFolder)
                    .disabled(store.busy || store.importing || store.movingSavedFiles || LiveNote.isActive(recorder.state))
            }.controlSize(.small)
        }
        Text(store.savedFolder.path).font(.system(size: 11)).foregroundStyle(LivePalette.secondary)
            .textSelection(.enabled).fixedSize(horizontal: false, vertical: true).padding(.bottom, 12)
        if store.movingSavedFiles {
            Text("Moving saved files…").font(.system(size: 11)).foregroundStyle(LivePalette.green).padding(.bottom, 12)
        }
        SettingRow(title: "Boost quiet audio", detail: "Raises quiet speech in notes and files when background noise is low. Original audio is kept unchanged.") {
            Switch(isOn: $settings.automaticAudioBoost)
        }
        SettingRow(title: "App updates", detail: "Updates replace the app. Downloaded models and saved files stay on this Mac.") {
            Button("Check for Updates…") { updater.check() }
                .disabled(!updater.canCheck || updater.activity.blockingReason != nil).controlSize(.small)
        }
        SettingRow(title: "Check automatically", detail: "Check for new releases daily. Installation asks for your confirmation.") {
            Switch(isOn: Binding(get: { updater.automaticallyChecks }, set: updater.setAutomaticChecks))
                .disabled(!updater.canCheck)
        }
        Text(updater.activity.blockingReason ?? updater.status).font(.system(size: 11)).foregroundStyle(LivePalette.secondary)
            .fixedSize(horizontal: false, vertical: true).padding(.bottom, 10)
        if updater.deferred {
            Button("Retry update") { updater.retryDeferredInstall() }.controlSize(.small).padding(.bottom, 10)
        }
        Rectangle().fill(LivePalette.line).frame(height: 1)
    }
    private func setLogin(_ on: Bool) {
        loginError = nil
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            loginError = "Could not change launch at login. \(error.localizedDescription)"
        }
        loginStatus = SMAppService.mainApp.status
        loginEnabled = loginStatus == .enabled || loginStatus == .requiresApproval
    }
}

// MARK: Dictation

private struct DictationPane: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var dictation: DictationController
    var body: some View {
        PaneHeader(title: "Dictation", subtitle: "Talk into any app. Text is transcribed on this Mac and typed where your cursor is.")
        SettingRow(title: "Dictation", detail: "Listen for the shortcut in every app.", divider: false) {
            Switch(isOn: $settings.dictationEnabled)
        }
        SettingRow(title: "Shortcut", detail: LiveFormat.dictationHint(settings.hotkey, settings.dictationMode) + " to talk.") {
            Picker("", selection: $settings.hotkey) {
                ForEach(HotkeyChoice.allCases) { Text($0.label).tag($0) }
            }.pickerStyle(.menu).labelsHidden().frame(width: 190)
        }.disabled(!settings.dictationEnabled)
        if settings.hotkey == .fn { LiveFnHint().padding(.bottom, 12) }
        SettingRow(title: "Mode") {
            Picker("", selection: $settings.dictationMode) {
                ForEach(DictationMode.allCases) { Text($0.label).tag($0) }
            }.pickerStyle(.menu).labelsHidden().frame(width: 270)
        }.disabled(!settings.dictationEnabled)
        SettingRow(title: "Auto paste", detail: "Puts the text into the focused app. When off, it is only copied.") {
            Switch(isOn: $settings.autoPaste)
        }
        SettingRow(title: "Restore clipboard", detail: "Puts back what you had copied after pasting.") {
            Switch(isOn: $settings.restoreClipboard)
        }.disabled(!settings.autoPaste)
        SettingRow(title: "Sounds", detail: "A short tone when listening starts and ends.") {
            Switch(isOn: $settings.sounds)
        }
        SettingRow(title: "Model", detail: "Dictation uses \(model.name). Change it in Models.") {
            OpenModelsButton { Text("Models…") }.buttonStyle(.plain).font(.system(size: 12, weight: .medium)).foregroundStyle(LivePalette.green)
        }
        SettingRow(title: "Live text", detail: liveTextDetail) {
            Picker("", selection: $settings.dictationLiveText) {
                ForEach(DictationLiveText.allCases) { Text($0.label).tag($0) }
            }.pickerStyle(.menu).labelsHidden().frame(width: 190)
        }.disabled(model.engine != .parakeet)
        Rectangle().fill(LivePalette.line).frame(height: 1)
        VStack(alignment: .leading, spacing: 8) {
            Text("Vocabulary").font(.system(size: 13))
            Text(model.usesPrompt ? "Names, brands and terms Whisper should expect, separated by commas. A hint for spelling, not a rule."
                 : "\(model.name) ignores this list. It is used again when dictation uses a Whisper model.")
                .font(.system(size: 11)).foregroundStyle(LivePalette.secondary).fixedSize(horizontal: false, vertical: true)
            TextField("WhisperDrop, Turbo, Gabriele", text: $settings.vocabulary, axis: .vertical)
                .textFieldStyle(.plain).font(.system(size: 13)).lineLimit(2...4)
                .padding(10).background(LivePalette.surface, in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(LivePalette.line))
        }.padding(.vertical, 14)
        .onChange(of: settings.dictationEnabled) { dictation.refresh() }
        .onChange(of: settings.hotkey) { dictation.refresh() }
        .onChange(of: settings.dictationMode) { dictation.refresh() }
    }
    private var model: TranscriptionModel { settings.model(for: .dictation) }
    private var liveTextDetail: String {
        guard model.engine == .parakeet else { return "Available with Parakeet v3. Whisper is too slow to update while you speak." }
        switch settings.dictationLiveText {
        case .inField where !settings.autoPaste: return "Turn on Auto paste to see the words in the text field. Until then they appear in the dictation bar."
        case .inField: return "Words appear in the text field while you speak. Native apps show every word and correct it in place. Browsers and other apps get words typed once they settle, about six seconds behind; the bar shows the newest ones."
        case .bar: return "Words appear in the dictation bar. The text is inserted when you finish."
        case .off: return "The text is inserted when you finish."
        }
    }
}

// MARK: Models

/// Opens Settings on the Models pane. Used by the sidebar, the main window and the Transcription menu.
struct OpenModelsButton<Label: View>: View {
    @Environment(\.openSettings) private var openSettings
    @AppStorage private var tab: String
    private let label: Label
    init(defaults: UserDefaults? = nil, @ViewBuilder label: () -> Label) {
        _tab = defaults.map { AppStorage(wrappedValue: SettingsView.Tab.general.rawValue, SettingsView.tabKey, store: $0) }
            ?? AppStorage(wrappedValue: SettingsView.Tab.general.rawValue, SettingsView.tabKey)
        self.label = label()
    }
    var body: some View {
        Button {
            tab = SettingsView.Tab.models.rawValue
            openSettings()
            NSApp.activate(ignoringOtherApps: true)
        } label: { label }
    }
}

extension OpenModelsButton where Label == Text {
    init(defaults: UserDefaults? = nil) { self.init(defaults: defaults) { Text("Models…") } }
}

private struct ModelsPane: View {
    @EnvironmentObject private var store: AppStore
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var host: ModelHost
    @EnvironmentObject private var recorder: NoteRecorder
    @State private var showTasks = false
    var body: some View {
        PaneHeader(title: "Models", subtitle: "Choose local models for transcription and text editing.")
        Text("Transcription").font(.system(size: 17, weight: .medium)).padding(.bottom, 12)
        statusCard.padding(.bottom, 14)
        ForEach(Array(TranscriptionModel.catalog.enumerated()), id: \.element.id) { index, model in
            ModelRow(model: model, divider: index > 0)
        }
        Rectangle().fill(LivePalette.line).frame(height: 1)
        if let warning = languageWarning {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "exclamationmark.circle").foregroundStyle(.red)
                Text(warning).font(.system(size: 11)).foregroundStyle(LivePalette.secondary).fixedSize(horizontal: false, vertical: true)
            }.padding(.vertical, 12)
        }
        tasks.padding(.top, 18)
        SettingRow(title: "Unload model", detail: "Frees memory when dictation and notes are idle. A recording note always keeps its model loaded. Keep model ready is also in the menu bar.") {
            Picker("", selection: $settings.residency) {
                ForEach(ModelResidency.allCases) { Text($0 == .always ? "Keep model ready" : $0.label).tag($0) }
            }.pickerStyle(.menu).labelsHidden().frame(width: 230)
        }
        Rectangle().fill(LivePalette.line).frame(height: 1)
        Text("Whisper GGML, Q5 quantization except Turbo Q8. Parakeet v3, NVIDIA weights with a 4-bit encoder on MLX. Downloads are verified before installation.")
            .font(.system(size: 11)).foregroundStyle(LivePalette.secondary).fixedSize(horizontal: false, vertical: true).padding(.top, 14)
            .onAppear { showTasks = ModelTask.allCases.contains { settings.ownModel(for: $0) != nil } }
            .onChange(of: settings.residency) { _, value in
                host.residency = value
                host.keepReady = settings.keepReady
                if settings.keepReady { LiveModels.prewarm(settings: settings, store: store, host: host) }
            }
        TextModelsPane()
    }

    private var statusCard: some View {
        HStack(spacing: 12) {
            Circle().fill(stateColor).frame(width: 7, height: 7)
            VStack(alignment: .leading, spacing: 3) {
                Text(stateTitle).font(.system(size: 13, weight: .medium)).foregroundStyle(isFailed ? Color.red : Color.white)
                Text(stateDetail).font(.system(size: 11)).foregroundStyle(LivePalette.secondary)
            }
            Spacer()
            switch host.state {
            case .unloaded, .failed:
                Button("Load now") { host.prewarm(settings.model(for: .dictation)) }.buttonStyle(LiveQuietButton())
                    .disabled(!store.downloaded.contains(settings.model(for: .dictation).id))
            case .loading, .ready, .busy:
                Button("Unload now") { host.unload() }.buttonStyle(LiveQuietButton())
                    .disabled(host.state == .busy || LiveNote.isActive(recorder.state))
            }
        }
        .padding(14).background(LivePalette.surface, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(LivePalette.line))
    }

    @ViewBuilder private var tasks: some View {
        Button { withAnimation(.easeOut(duration: 0.15)) { showTasks.toggle() } } label: {
            HStack(spacing: 6) {
                Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold)).rotationEffect(.degrees(showTasks ? 90 : 0))
                Text("Advanced: a different model for each task").font(.system(size: 13))
                Spacer()
            }.contentShape(Rectangle())
        }.buttonStyle(.plain).padding(.bottom, 4)
        if showTasks {
            Text("For example, Parakeet v3 for dictation and Whisper for lectures. Switching between two models reloads the speech model, which takes a few seconds.")
                .font(.system(size: 11)).foregroundStyle(LivePalette.secondary).fixedSize(horizontal: false, vertical: true).padding(.bottom, 4)
            ForEach(ModelTask.allCases) { task in
                SettingRow(title: task.label, divider: task != .dictation) {
                    Picker("", selection: Binding(get: { settings.ownModel(for: task) ?? "" }, set: { settings.setOwnModel($0.isEmpty ? nil : $0, for: task) })) {
                        Text("Main model (\(settings.model.name))").tag("")
                        Divider()
                        ForEach(TranscriptionModel.catalog.filter { store.downloaded.contains($0.id) && $0.id != settings.mainModel }) { model in
                            Text(model.name).tag(model.id)
                        }
                        if let own = settings.ownModel(for: task), !store.downloaded.contains(own) {
                            Text("\(settings.model(for: task).name) (not downloaded)").tag(own)
                        }
                    }.pickerStyle(.menu).labelsHidden().frame(width: 230)
                }
            }
        }
        Rectangle().fill(LivePalette.line).frame(height: 1)
    }

    private var languageWarning: String? {
        let unsupported = ModelTask.allCases.filter { !settings.model(for: $0).supports(language: settings.spokenLanguage) }
        guard !unsupported.isEmpty else { return nil }
        let names = Set(unsupported.map { settings.model(for: $0).name }).sorted().joined(separator: " and ")
        return "\(names) does not transcribe \(LiveFormat.language(settings.spokenLanguage)), your spoken language. Choose a Whisper model, or change the language in General."
    }
    private var isFailed: Bool { if case .failed = host.state { true } else { false } }
    private var stateColor: Color {
        switch host.state {
        case .ready, .busy: LivePalette.green
        case .loading: LivePalette.green.opacity(0.45)
        case .unloaded: LivePalette.secondary
        case .failed: .red
        }
    }
    private var stateTitle: String {
        switch host.state {
        case .unloaded: "Unloaded"
        case .loading: "Loading"
        case .ready: "Ready"
        case .busy: "Transcribing"
        case .failed(let message): message
        }
    }
    private var stateDetail: String {
        let name = host.loadedModel.flatMap { id in TranscriptionModel.catalog.first { $0.id == id }?.name }
        switch host.state {
        case .unloaded, .failed: return "Loads on the first dictation or note."
        case .loading: return "Starting \(name ?? settings.model(for: .dictation).name)."
        case .ready, .busy: return "\(name ?? settings.model(for: .dictation).name) is in memory."
        }
    }
}

/// One catalog entry: download, use as the main model, or delete.
private struct ModelRow: View {
    @EnvironmentObject private var store: AppStore
    @EnvironmentObject private var settings: AppSettings
    let model: TranscriptionModel
    var divider = true
    var body: some View {
        let downloaded = store.downloaded.contains(model.id)
        let main = settings.mainModel == model.id
        VStack(spacing: 0) {
            if divider { Rectangle().fill(LivePalette.line).frame(height: 1) }
            HStack(alignment: .center, spacing: 14) {
                Image(systemName: main ? "largecircle.fill.circle" : "circle")
                    .font(.system(size: 14)).foregroundStyle(main ? LivePalette.green : LivePalette.secondary.opacity(downloaded ? 1 : 0.4))
                    .frame(width: 18)
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text(model.name).font(.system(size: 13, weight: .medium))
                        Text(model.size).font(.system(size: 11)).foregroundStyle(LivePalette.secondary)
                        if model.experimental {
                            Text("Experimental").font(.system(size: 10, weight: .medium)).foregroundStyle(LivePalette.green)
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(LivePalette.green.opacity(0.6)))
                        }
                        if let tasks = taskNote { Text(tasks).font(.system(size: 11)).foregroundStyle(LivePalette.green) }
                    }
                    Text(model.detail).font(.system(size: 11)).foregroundStyle(LivePalette.secondary).fixedSize(horizontal: false, vertical: true)
                    if store.downloadingModel == model.id {
                        HStack(spacing: 8) {
                            ProgressView(value: store.modelProgress).frame(width: 200)
                            Text("\(Int(store.modelProgress * 100))%").font(.system(size: 11)).monospacedDigit().foregroundStyle(LivePalette.secondary)
                        }
                    }
                }
                Spacer(minLength: 12)
                if store.downloadingModel == model.id {
                    Button("Cancel", action: store.cancelModelDownload).buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(LivePalette.green)
                } else if downloaded {
                    if main {
                        Text("In use").font(.system(size: 12, weight: .medium)).foregroundStyle(LivePalette.green)
                    } else {
                        Button("Use") { settings.mainModel = model.id }.buttonStyle(LiveQuietButton())
                    }
                    Button { store.deleteModel(model) } label: { Image(systemName: "trash").foregroundStyle(LivePalette.secondary) }
                        .buttonStyle(.plain).disabled(store.busy || store.downloadingModel != nil)
                        .help("Delete \(model.name)").accessibilityLabel("Delete \(model.name)")
                } else {
                    Button("Download") { store.downloadModel(model) }.buttonStyle(LiveQuietButton())
                        .disabled(store.busy || store.downloadingModel != nil)
                        .accessibilityLabel("Download \(model.name)")
                }
            }
            .padding(.vertical, 12)
            .contentShape(Rectangle())
            .onTapGesture { if downloaded { settings.mainModel = model.id } }
        }
    }
    /// Tasks that use this model through their own choice, or "Not downloaded" for the main model.
    private var taskNote: String? {
        if settings.mainModel == model.id, !store.downloaded.contains(model.id) { return "Selected, not downloaded" }
        let own = ModelTask.allCases.filter { settings.ownModel(for: $0) == model.id }.map(\.shortLabel)
        return own.isEmpty ? nil : "Used for " + own.joined(separator: ", ")
    }
}

/// Loads the model that has to answer first: dictation's.
@MainActor enum LiveModels {
    static func prewarm(settings: AppSettings, store: AppStore, host: ModelHost) {
        let model = settings.model(for: .dictation)
        if store.downloaded.contains(model.id) { host.prewarm(model) }
    }
}

// MARK: Notes

private struct NotesPane: View {
    @EnvironmentObject private var settings: AppSettings
    var body: some View {
        let model = settings.model(for: .notes)
        PaneHeader(title: "Notes", subtitle: "Record a call, a lecture or a meeting. The transcript builds while you record.")
        SettingRow(title: "Default source", detail: "You is the microphone. Others is audio from other apps.", divider: false) {
            Picker("", selection: $settings.noteSources) {
                ForEach(NoteSources.allCases) { Text($0.label).tag($0) }
            }.pickerStyle(.menu).labelsHidden().frame(width: 230)
        }
        SettingRow(title: "Model", detail: "Notes use \(model.name). Change it in Models.") {
            OpenModelsButton { Text("Models…") }.buttonStyle(.plain).font(.system(size: 12, weight: .medium)).foregroundStyle(LivePalette.green)
        }
        SettingRow(title: "Live text", detail: model.engine == .parakeet
                   ? "Shows the words heard since the last confirmed paragraph, in grey, while you record."
                   : "Available with Parakeet v3. With Whisper, text appears after a pause or about a minute of speech.") {
            Switch(isOn: $settings.noteLiveText)
        }.disabled(model.engine != .parakeet)
        SettingRow(title: "Words and names", detail: model.usesPrompt ? "Try a short list of subject terms in the spoken language."
                   : "\(model.name) ignores this list. It is used with Whisper models.") {
            TextField("Subject terms", text: $settings.noteVocabulary).textFieldStyle(.roundedBorder).frame(width: 230)
        }
        SettingRow(title: "Keep audio", detail: "Saves the original recording in your Audio folder. When off, it is deleted once the transcript is saved. Also beside New note.") {
            Switch(isOn: $settings.keepNoteAudio)
        }
        Rectangle().fill(LivePalette.line).frame(height: 1)
    }
}

// MARK: Permissions

private struct PermissionsPane: View {
    @EnvironmentObject private var permissions: Permissions
    @EnvironmentObject private var settings: AppSettings
    @AppStorage("guideDone") private var guideDone = false
    @Environment(\.openWindow) private var openWindow
    private let poll = Timer.publish(every: 1.5, on: .main, in: .common).autoconnect()
    var body: some View {
        PaneHeader(title: "Permissions", subtitle: "macOS asks once for each. You can change them any time in System Settings.")
        ForEach(Array(Permissions.Kind.allCases.enumerated()), id: \.element) { index, kind in
            if index > 0 { Rectangle().fill(LivePalette.line).frame(height: 1) }
            LivePermissionRow(kind: kind)
        }
        Rectangle().fill(LivePalette.line).frame(height: 1)
        Text("If the shortcut still does nothing after allowing Input Monitoring, quit and reopen WhisperDrop 2.")
            .font(.system(size: 11)).foregroundStyle(LivePalette.secondary).fixedSize(horizontal: false, vertical: true).padding(.top, 14)
        if settings.hotkey == .fn { LiveFnHint().padding(.top, 14) }
        Button("Show the guide again") {
            guideDone = false
            openWindow(id: "main")
            NSApp.activate(ignoringOtherApps: true)
        }.buttonStyle(.plain)
            .font(.system(size: 11, weight: .medium)).foregroundStyle(LivePalette.green).padding(.top, 16)
            .onReceive(poll) { _ in permissions.refresh() }
    }
}
