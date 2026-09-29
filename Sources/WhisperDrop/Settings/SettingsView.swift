import SwiftUI
import Combine
import AppKit
import ServiceManagement
import WhisperDropCore

/// Contract file. Settings window content. Reads AppStore, AppSettings, ModelHost, DictationController and Permissions from the environment.
struct SettingsView: View {
    fileprivate enum Tab: String, CaseIterable, Identifiable {
        case general = "General", dictation = "Dictation", model = "Model", notes = "Notes", permissions = "Permissions"
        var id: String { rawValue }
        var symbol: String {
            switch self {
            case .general: "gearshape"
            case .dictation: "waveform"
            case .model: "cpu"
            case .notes: "note.text"
            case .permissions: "lock.shield"
            }
        }
    }
    @EnvironmentObject private var permissions: Permissions
    @State private var tab: Tab = .general
    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text("WhisperDrop").font(.system(size: 15, weight: .semibold, design: .rounded))
                    Text("2").font(.system(size: 11, weight: .medium)).foregroundStyle(LivePalette.green)
                }.padding(.horizontal, 12).padding(.top, 40).padding(.bottom, 18)
                ForEach(Tab.allCases) { item in
                    Button { tab = item } label: {
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
                    case .model: ModelPane()
                    case .notes: NotesPane()
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
    @State private var loginEnabled = SMAppService.mainApp.status == .enabled
    @State private var loginStatus = SMAppService.mainApp.status
    @State private var loginError: String?
    var body: some View {
        PaneHeader(title: "General", subtitle: "How WhisperDrop 2 sits on your Mac.")
        SettingRow(title: "Launch at login", detail: "Keeps dictation ready from the menu bar after you sign in.", divider: false) {
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
        SettingRow(title: "Auto paste", detail: "Types the text into the focused app. When off, it is only copied.") {
            Switch(isOn: $settings.autoPaste)
        }
        SettingRow(title: "Restore clipboard", detail: "Puts back what you had copied after pasting.") {
            Switch(isOn: $settings.restoreClipboard)
        }.disabled(!settings.autoPaste)
        SettingRow(title: "Sounds", detail: "A short tone when listening starts and ends.") {
            Switch(isOn: $settings.sounds)
        }
        SettingRow(title: "Language") { LanguagePicker(code: $settings.dictationLanguage) }
        Rectangle().fill(LivePalette.line).frame(height: 1)
        VStack(alignment: .leading, spacing: 8) {
            Text("Vocabulary").font(.system(size: 13))
            Text("Names, brands and terms Whisper should expect, separated by commas. A hint for spelling, not a rule.")
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
}

// MARK: Model

private struct ModelPane: View {
    @EnvironmentObject private var store: AppStore
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var host: ModelHost
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        let downloaded = TranscriptionModel.catalog.filter { store.downloaded.contains($0.id) }
        PaneHeader(title: "Model", subtitle: "Dictation and notes share one Whisper model that stays loaded while you use it.")
        HStack(spacing: 12) {
            Circle().fill(stateColor).frame(width: 7, height: 7)
            VStack(alignment: .leading, spacing: 3) {
                Text(stateTitle).font(.system(size: 13, weight: .medium)).foregroundStyle(isFailed ? Color.red : Color.white)
                Text(stateDetail).font(.system(size: 11)).foregroundStyle(LivePalette.secondary)
            }
            Spacer()
            switch host.state {
            case .unloaded, .failed:
                Button("Load now") { host.prewarm(settings.model) }.buttonStyle(LiveQuietButton())
                    .disabled(!store.downloaded.contains(settings.liveModel))
            case .loading, .ready, .busy:
                Button("Unload now") { host.unload() }.buttonStyle(LiveQuietButton()).disabled(host.state == .busy)
            }
        }
        .padding(14).background(LivePalette.surface, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(LivePalette.line)).padding(.bottom, 14)

        SettingRow(title: "Live model", detail: "Used for dictation and notes. Turbo is the usual choice.", divider: false) {
            if downloaded.isEmpty {
                Text("No models yet").font(.system(size: 12)).foregroundStyle(LivePalette.secondary)
            } else {
                Picker("", selection: $settings.liveModel) {
                    ForEach(downloaded) { Text($0.name).tag($0.id) }
                    if !store.downloaded.contains(settings.liveModel) {
                        Text("\(settings.model.name) (not downloaded)").tag(settings.liveModel)
                    }
                }.pickerStyle(.menu).labelsHidden().frame(width: 190)
            }
        }
        HStack(spacing: 10) {
            if !store.downloaded.contains(settings.liveModel) {
                Image(systemName: "exclamationmark.circle").foregroundStyle(.red)
                Text("\(settings.model.name) is not downloaded yet.").font(.system(size: 11)).foregroundStyle(LivePalette.secondary)
            }
            Spacer()
            Button("Manage models") {
                openWindow(id: "main")
                NSApp.activate(ignoringOtherApps: true)
                store.showModels = true
            }.buttonStyle(.plain).font(.system(size: 11, weight: .medium)).foregroundStyle(LivePalette.green)
        }.padding(.bottom, 12)
        SettingRow(title: "Keep model ready", detail: "Never unload. Uses memory, but the first word is instant.") {
            Switch(isOn: $settings.keepReady)
        }
        SettingRow(title: "Unload model", detail: settings.keepReady ? "Off while Keep model ready is on." : "Frees memory when dictation and notes are idle. A note always keeps it loaded.") {
            Picker("", selection: $settings.residency) {
                ForEach(ModelResidency.allCases) { Text($0.label).tag($0) }
            }.pickerStyle(.menu).labelsHidden().frame(width: 230)
        }.disabled(settings.keepReady)
        Rectangle().fill(LivePalette.line).frame(height: 1)
            .onChange(of: settings.keepReady) { _, on in
                host.keepReady = on
                if on, store.downloaded.contains(settings.liveModel) { host.prewarm(settings.model) }
            }
            .onChange(of: settings.residency) { _, value in host.residency = value }
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
        case .unloaded, .failed: return "Loads on first dictation or note."
        case .loading: return "Starting \(name ?? settings.model.name)."
        case .ready, .busy: return "\(name ?? settings.model.name) is in memory."
        }
    }
}

// MARK: Notes

private struct NotesPane: View {
    @EnvironmentObject private var settings: AppSettings
    var body: some View {
        PaneHeader(title: "Notes", subtitle: "Record a call, a lecture or a meeting. The transcript builds while you record.")
        SettingRow(title: "Default source", detail: "You is the microphone. Others is audio from other apps.", divider: false) {
            Picker("", selection: $settings.noteSources) {
                ForEach(NoteSources.allCases) { Text($0.label).tag($0) }
            }.pickerStyle(.menu).labelsHidden().frame(width: 230)
        }
        SettingRow(title: "Language") { LanguagePicker(code: $settings.noteLanguage) }
        SettingRow(title: "Words and names", detail: "Try a short list of subject terms in the spoken language.") {
            TextField("Subject terms", text: $settings.noteVocabulary).textFieldStyle(.roundedBorder).frame(width: 230)
        }
        SettingRow(title: "Keep the recording", detail: "Saves the audio next to the transcript. When off, it is deleted once the transcript is saved.") {
            Switch(isOn: $settings.keepNoteAudio)
        }
        Rectangle().fill(LivePalette.line).frame(height: 1)
    }
}

// MARK: Permissions

private struct PermissionsPane: View {
    @EnvironmentObject private var permissions: Permissions
    @EnvironmentObject private var settings: AppSettings
    @AppStorage("permissionsOnboardingDone") private var onboardingDone = false
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
        Button("Show setup again") { onboardingDone = false }.buttonStyle(.plain)
            .font(.system(size: 11, weight: .medium)).foregroundStyle(LivePalette.green).padding(.top, 16)
            .onReceive(poll) { _ in permissions.refresh() }
    }
}
