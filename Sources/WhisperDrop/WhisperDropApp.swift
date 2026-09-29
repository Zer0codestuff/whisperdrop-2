import SwiftUI
import AppKit

@main
struct WhisperDropApp: App {
    @StateObject private var store: AppStore
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    init() {
        let arguments = ProcessInfo.processInfo.arguments
        let root: URL?
        if let i = arguments.firstIndex(of: "--data-dir"), arguments.indices.contains(i + 1) {
            root = URL(fileURLWithPath: arguments[i + 1])
        } else { root = nil }
        _store = StateObject(wrappedValue: AppStore(root: root))
    }
    var body: some Scene {
        Window("WhisperDrop 2", id: "main") {
            ContentView().environmentObject(store)
                .preferredColorScheme(.dark)
                .onOpenURL { url in if url.isFileURL { store.addFiles([url]) } }
                .task { delegate.store = store; await runVerificationIfRequested() }
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
                Button("Manage models…") { store.showModels = true }.keyboardShortcut(",")
                Button("Show activity…") { store.showDiagnostics = true }
            }
            CommandGroup(replacing: .appInfo) {
                Button("About WhisperDrop 2") {
                    NSApp.orderFrontStandardAboutPanel(options: [.applicationName: "WhisperDrop 2", .applicationVersion: "2.0.0", .credits: NSAttributedString(string: "Local transcription for macOS.\nOriginally started with Luca Arisci.\ngithub.com/LucaArisci/whisper-drop")])
                }
            }
        }
    }
    @MainActor private func runVerificationIfRequested() async {
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: "--verify-audio"), args.indices.contains(i + 1) else { return }
        store.selectedModel = "tiny"
        store.language = "en"
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
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let store, store.busy || store.importing || store.downloadingModel != nil else { return .terminateNow }
        store.cancelAll()
        Task {
            while store.busy || store.importing || store.downloadingModel != nil {
                try? await Task.sleep(for: .milliseconds(100))
            }
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}
