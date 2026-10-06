import SwiftUI
import AppKit
import WhisperDropCore

@main
struct WhisperDropApp: App {
    @StateObject private var store: AppStore
    @StateObject private var settings: AppSettings
    @StateObject private var host: ModelHost
    @StateObject private var permissions: Permissions
    @StateObject private var dictation: DictationController
    @StateObject private var recorder: NoteRecorder
    @StateObject private var writingSettings: WritingSettings
    @StateObject private var textModels: TextModelStore
    @StateObject private var textEngine: TextGenerationEngine
    @StateObject private var writing: WritingController
    @StateObject private var updater: AppUpdater
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    private let appDefaults: UserDefaults
    init() {
        let arguments = ProcessInfo.processInfo.arguments
        let root: URL?
        if let i = arguments.firstIndex(of: "--data-dir"), arguments.indices.contains(i + 1) {
            root = URL(fileURLWithPath: arguments[i + 1])
        } else if Bundle.main.bundleIdentifier == UpdateConfiguration.verificationBundleID,
                  let path = Bundle.main.object(forInfoDictionaryKey: "WDUpdateVerificationDataDirectory") as? String {
            // An isolated update must retain its data directory when Sparkle relaunches without CLI arguments.
            root = URL(fileURLWithPath: path)
        } else { root = nil }
        let defaults = root == nil ? UserDefaults.standard : UserDefaults(suiteName: "io.github.zer0codestuff.whisperdrop2.verification")!
        appDefaults = defaults
        let store = AppStore(root: root)
        let settings = AppSettings(defaults: defaults)
        let writingSettings = WritingSettings(defaults: defaults)
        let textModels = TextModelStore(folder: store.root.appendingPathComponent("TextModels"))
        let textEngine = TextGenerationEngine(runtime: { try store.tool("llama-server") }, processFile: store.root.appendingPathComponent("text-engine.pid"))
        let writing = WritingController(settings: writingSettings, models: textModels, engine: textEngine, store: store, defaults: defaults)
        let host = ModelHost(tool: { try store.tool($0) }, modelFile: { model in
            let file = model.location(in: store.modelsFolder)
            guard FileManager.default.fileExists(atPath: file.path) else {
                throw AppFailure("Download the \(model.name) model in Settings, Models first.")
            }
            return file
        }, processFile: root?.appendingPathComponent("whisper-server.pid"))
        host.residency = settings.residency
        host.keepReady = settings.keepReady
        let permissions = Permissions()
        let dictation = DictationController(settings: settings, host: host)
        let recorder = NoteRecorder(
            settings: settings,
            host: host,
            folder: store.audioFolder,
            onFinish: { store.addNote($0); writing.noteFinished($0) }, defaults: defaults,
            folderProvider: { (audio: store.audioFolder, transcripts: store.outputFolder) }
        )
        store.canMoveSavedFiles = { [weak recorder] in recorder.map { !LiveNote.isActive($0.state) } ?? true }
        store.audioBoostEnabled = { [weak settings] in settings?.automaticAudioBoost ?? true }
        store.spokenLanguage = { [weak settings] in settings?.spokenLanguage ?? "auto" }
        store.fileModel = { [weak settings] in settings?.model(for: .files) ?? TranscriptionModel.catalog.first { $0.id == "turbo" }! }
        recorder.canStartRecording = { [weak store] in store?.canRecordNotes ?? false }
        recorder.modelInstalled = { [weak store] model in store?.downloaded.contains(model.id) ?? false }
        dictation.modelInstalled = { [weak store] model in store?.downloaded.contains(model.id) ?? false }
        dictation.onBegin = { [weak writing] in writing?.suspendForCapture() }
        dictation.onComplete = { [weak writing] text, target in writing?.afterDictation(text, target: target) }
        writing.canGenerate = { [weak dictation, weak recorder] in
            guard let dictation, let recorder else { return false }
            return !LiveNote.isActive(recorder.state) && dictation.state == .idle
        }
        writing.observeCapture(recorder: recorder, dictation: dictation)
        let updater = AppUpdater()
        updater.currentActivity = { [weak store, weak recorder, weak dictation, weak writing, weak textModels] in
            var activity = UpdateActivity()
            activity.recording = recorder.map { LiveNote.isActive($0.state) } ?? false
            activity.dictating = dictation.map { $0.state != .idle } ?? false
            activity.transcribing = store?.busy ?? false; activity.importing = store?.importing ?? false
            activity.movingFiles = store?.movingSavedFiles ?? false
            activity.downloadingModel = store?.downloadingModel != nil || textModels?.downloadingID != nil
            activity.editing = writing?.hasActiveWritingWork == true
            activity.replacingText = writing?.replacing ?? false
            activity.reviewingSelection = writing?.hasOpenReviewPanel ?? false
            return activity
        }
        updater.prepareToRestart = { [weak writing] in try writing?.saveDraftForUpdate() }
        updater.observe([store.objectWillChange.eraseToAnyPublisher(), recorder.objectWillChange.eraseToAnyPublisher(),
                         dictation.objectWillChange.eraseToAnyPublisher(), writing.objectWillChange.eraseToAnyPublisher(),
                         textModels.objectWillChange.eraseToAnyPublisher()])
        _store = StateObject(wrappedValue: store)
        _settings = StateObject(wrappedValue: settings)
        _host = StateObject(wrappedValue: host)
        _permissions = StateObject(wrappedValue: permissions)
        _dictation = StateObject(wrappedValue: dictation)
        _recorder = StateObject(wrappedValue: recorder)
        _writingSettings = StateObject(wrappedValue: writingSettings)
        _textModels = StateObject(wrappedValue: textModels)
        _textEngine = StateObject(wrappedValue: textEngine)
        _writing = StateObject(wrappedValue: writing)
        _updater = StateObject(wrappedValue: updater)
    }
    var body: some Scene {
        Window("WhisperDrop 2", id: "main") {
            connected(ContentView())
                .onOpenURL { url in if url.isFileURL { writing.showLibrary(); store.addFiles([url]) } }
                .task { bindDelegate(); await runVerificationIfRequested() }
        }
        .defaultSize(width: 1120, height: 740)
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Add files…") { store.chooseFiles() }.keyboardShortcut("o")
                Button("Add YouTube link…") { store.showLink = true }.keyboardShortcut("l")
            }
            CommandMenu("Transcription") {
                Button("Transcribe queue") { store.start() }.keyboardShortcut(.return, modifiers: .command).disabled(store.busy || store.queuedCount == 0)
                Button("Stop transcription") { store.cancel() }.disabled(!store.busy)
                Divider()
                OpenModelsButton(defaults: appDefaults).keyboardShortcut("m", modifiers: [.command, .shift])
                Button("Show activity…") { store.showDiagnostics = true }
            }
            CommandMenu("Writing") {
                OpenWritingEditorButton(controller: writing)
                Button("Improve last dictation") {
                    if let text = dictation.recent.first { writing.openServiceText(text) }
                }.disabled(dictation.recent.isEmpty)
            }
            CommandGroup(replacing: .help) { GuideMenuItem(defaults: appDefaults) }
            CommandGroup(replacing: .appInfo) {
                Button("About WhisperDrop 2") {
                    let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Development"
                    NSApp.orderFrontStandardAboutPanel(options: [.applicationName: "WhisperDrop 2", .applicationVersion: version, .credits: NSAttributedString(string: "Local transcription for macOS.")])
                }
                Button("Check for Updates…") { updater.check() }
                    .disabled(!updater.canCheck || updater.activity.blockingReason != nil)
            }
        }
        MenuBarExtra {
            connected(MenuBarContent())
        } label: {
            MenuBarLabel()
                .environmentObject(dictation)
                .environmentObject(recorder)
        }
        .menuBarExtraStyle(.window)
        Settings {
            connected(SettingsView())
        }
    }
    private func connected<V: View>(_ view: V) -> some View {
        view
            .environmentObject(store)
            .environmentObject(settings)
            .environmentObject(host)
            .environmentObject(permissions)
            .environmentObject(dictation)
            .environmentObject(recorder)
            .environmentObject(writingSettings)
            .environmentObject(textModels)
            .environmentObject(textEngine)
            .environmentObject(writing)
            .environmentObject(updater)
            .preferredColorScheme(.dark)
            .defaultAppStorage(appDefaults)
    }
    @MainActor private func bindDelegate() {
        delegate.store = store
        delegate.settings = settings
        delegate.host = host
        delegate.dictation = dictation
        delegate.recorder = recorder
        delegate.writing = writing
        delegate.updater = updater
        updater.start()
        NSApp.servicesProvider = delegate
        NSUpdateDynamicServices()
        host.residency = settings.residency
        host.keepReady = settings.keepReady
        dictation.refresh()
        AppDelegate.applyDockPolicy(settings.showInDock)
    }
    @MainActor private func runVerificationIfRequested() async {
        let args = ProcessInfo.processInfo.arguments
        if let i = args.firstIndex(of: "--verify-dictation"), args.indices.contains(i + 1) {
            // Silent dictation from a file into whatever has focus after the delay. For live text checks.
            let delay = args.firstIndex(of: "--verify-dictation-delay").flatMap { args.indices.contains($0 + 1) ? Double(args[$0 + 1]) : nil } ?? 5
            try? await Task.sleep(for: .seconds(delay))
            do { try dictation.replay(URL(fileURLWithPath: args[i + 1])) } catch { store.error = error.localizedDescription }
            return
        }
        guard let i = args.firstIndex(of: "--verify-audio"), args.indices.contains(i + 1) else { return }
        let model = args.firstIndex(of: "--verify-model").flatMap { args.indices.contains($0 + 1) ? args[$0 + 1] : nil }
        let language = args.firstIndex(of: "--verify-language").flatMap { args.indices.contains($0 + 1) ? args[$0 + 1] : nil }
        let verificationModel = TranscriptionModel.catalog.first { $0.id == (model ?? "tiny") } ?? TranscriptionModel.catalog[0]
        store.fileModel = { verificationModel }
        store.spokenLanguage = { language ?? "en" }
        store.addFiles([URL(fileURLWithPath: args[i + 1])])
        store.start()
        while store.busy { try? await Task.sleep(for: .milliseconds(250)) }
        let success = store.jobs.first?.status == .completed && !(store.jobs.first?.transcript.isEmpty ?? true)
        let report: [String: Any] = ["success": success, "transcript": store.jobs.first?.transcript ?? "", "error": store.error ?? store.jobs.first?.error ?? "", "diagnostics": store.diagnostics]
        if let j = args.firstIndex(of: "--verification-report"), args.indices.contains(j + 1), let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: URL(fileURLWithPath: args[j + 1]))
        }
        if args.contains("--quit-after-verification") { NSApp.terminate(nil) }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var store: AppStore?
    weak var settings: AppSettings?
    weak var host: ModelHost?
    weak var dictation: DictationController?
    weak var recorder: NoteRecorder?
    weak var writing: WritingController?
    weak var updater: AppUpdater?
    @objc func improveText(_ pasteboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        guard let text = pasteboard.string(forType: .string), !text.isEmpty else {
            error.pointee = "Select some text first."
            return
        }
        writing?.openServiceText(text)
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // Sparkle may install a previously downloaded update when the app quits later.
        // Keep the draft durable on every normal quit as well as on the explicit restart path.
        do { try writing?.saveDraftForUpdate() }
        catch {
            let alert = NSAlert(); alert.messageText = "Could not save your writing draft"
            alert.informativeText = error.localizedDescription + " Keep the app open and copy your text before quitting."
            alert.addButton(withTitle: "Keep Open"); alert.runModal()
            return .terminateCancel
        }
        recorder?.finishForTermination()
        guard needsToWait else {
            host?.shutdown()
            writing?.shutdown()
            store?.shutdownEngines()
            return .terminateNow
        }
        store?.cancelAll()
        Task {
            let deadline = Date().addingTimeInterval(30)
            while Date() < deadline, needsToWait {
                try? await Task.sleep(for: .milliseconds(100))
            }
            host?.shutdown()
            writing?.shutdown()
            store?.shutdownEngines()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
    private var needsToWait: Bool {
        let storeBusy = store?.busy == true || store?.importing == true || store?.downloadingModel != nil || store?.movingSavedFiles == true
        let noteBusy = recorder.map { LiveNote.isActive($0.state) } ?? false
        return storeBusy || noteBusy
    }
    func applicationWillTerminate(_ notification: Notification) {
        recorder?.finishForTermination()
        host?.shutdown()
        writing?.shutdown()
        store?.shutdownEngines()
    }
    func applicationDidFinishLaunching(_ notification: Notification) {
        if let settings, let host {
            host.residency = settings.residency
            host.keepReady = settings.keepReady
        }
        dictation?.refresh()
        Self.applyDockPolicy(settings?.showInDock ?? true)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    static func applyDockPolicy(_ showInDock: Bool) {
        NSApp.setActivationPolicy(showInDock ? .regular : .accessory)
        if showInDock { NSApp.activate(ignoringOtherApps: true) }
    }
}
