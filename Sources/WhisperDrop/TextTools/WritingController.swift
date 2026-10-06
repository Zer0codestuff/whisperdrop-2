import AppKit
import Combine
import UniformTypeIdentifiers
import WhisperDropCore

@MainActor
final class WritingController: ObservableObject {
    @Published var source = ""
    @Published var result = ""
    @Published var instruction = ""
    @Published var chosenActionID = "grammar"
    @Published private(set) var busy = false
    @Published private(set) var replacing = false
    @Published var error: String?
    @Published private(set) var contextTitle = "Writing tools"
    @Published private(set) var saved = false
    @Published private(set) var processingNotes: Set<UUID> = []
    @Published var showChanges = true
    @Published private(set) var editorVisible = false
    let settings: WritingSettings
    let models: TextModelStore
    let engine: TextGenerationEngine
    let defaults: UserDefaults
    private weak var store: AppStore?
    private let selectionService = TextSelectionService()
    private let shortcut = TextToolsShortcut()
    private var snapshot: TextSelectionSnapshot?
    private var jobID: UUID?
    private var original = ""
    private var resultSource = ""
    private var resultModelName = ""
    private var resultAction: TextAction?
    private var work: Task<Void, Never>?
    private var captureWork: Task<Void, Never>?
    private var replaceWork: Task<Void, Never>?
    private var automaticWork: Task<Void, Never>?
    private var pendingNotes: [UUID] = []
    private var bindings: Set<AnyCancellable> = []
    private var generation = UUID()
    private var captureGeneration = UUID()
    private var shuttingDown = false
    private var panel: WritingPanelController?
    private let presentsPanels: Bool
    private let isOwnAppFrontmost: @MainActor () -> Bool
    private var panelSessionActive = false
    private var retainedEditor: EditingSession?
    private var pendingPanel: PanelRequest?
    private var unreadableDraft = false
    var canGenerate: () -> Bool = { true }

    /// Value state for the inline editor while a transient panel owns the shared view bindings.
    private struct EditingSession {
        let source: String
        let result: String
        let instruction: String
        let chosenActionID: String
        let contextTitle: String
        let saved: Bool
        let error: String?
        let showChanges: Bool
        let visible: Bool
        let snapshot: TextSelectionSnapshot?
        let jobID: UUID?
        let original: String
        let resultSource: String
        let resultModelName: String
        let resultAction: TextAction?
    }

    private struct PanelRequest {
        let text: String
        let title: String
        var snapshot: TextSelectionSnapshot? = nil
        var error: String? = nil
    }

    init(settings: WritingSettings, models: TextModelStore, engine: TextGenerationEngine, store: AppStore,
         defaults: UserDefaults = .standard, presentsPanels: Bool = true,
         isOwnAppFrontmost: (@MainActor () -> Bool)? = nil) {
        self.settings = settings; self.models = models; self.engine = engine; self.store = store
        self.defaults = defaults
        self.presentsPanels = presentsPanels
        self.isOwnAppFrontmost = isOwnAppFrontmost ?? {
            NSWorkspace.shared.frontmostApplication?.processIdentifier == ProcessInfo.processInfo.processIdentifier
        }
        settings.$shortcut.removeDuplicates().sink { [weak self] choice in
            self?.shortcut.start(choice: choice) { [weak self] in self?.invokeSelection() }
        }.store(in: &bindings)
        settings.$modelID.dropFirst().removeDuplicates().sink { [weak self] _ in
            self?.cancel(); self?.automaticWork?.cancel(); self?.engine.unload()
        }.store(in: &bindings)
        settings.$contextMode.dropFirst().removeDuplicates().sink { [weak self] _ in
            self?.cancel(); self?.automaticWork?.cancel(); self?.engine.unload()
        }.store(in: &bindings)
        restoreDraftAfterUpdate()
    }

    var canReplace: Bool { snapshot?.canReplace == true && jobID == nil && !result.isEmpty && source == resultSource }
    var canSave: Bool { jobID != nil && !result.isEmpty && source == resultSource && !saved }
    var hasSource: Bool { !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    var action: TextAction { settings.action(id: chosenActionID) ?? TextAction.defaults[0] }
    var shortcutError: String? { shortcut.error }
    var model: TextModel { models.model(id: settings.modelID) ?? models.catalog[0] }
    var hasOpenReviewPanel: Bool { panelSessionActive }
    var hasActiveWritingWork: Bool { busy || automaticWork != nil || !pendingNotes.isEmpty }

    /// Durable editor state only. Cross-app Accessibility references never survive a restart.
    private struct Draft: Codable {
        let source: String
        let result: String
        let instruction: String
        let chosenActionID: String
        let contextTitle: String
        let saved: Bool
        let showChanges: Bool
        let visible: Bool
        let jobID: UUID?
        let original: String
        let resultSource: String
        let resultModelName: String
        let resultAction: TextAction?
        init(_ session: EditingSession) {
            source = session.source; result = session.result; instruction = session.instruction
            chosenActionID = session.chosenActionID; contextTitle = session.contextTitle; saved = session.saved
            showChanges = session.showChanges; visible = session.visible; jobID = session.jobID
            original = session.original; resultSource = session.resultSource
            resultModelName = session.resultModelName; resultAction = session.resultAction
        }
    }

    func saveDraftForUpdate() throws {
        guard let store else { return }
        let file = store.root.appendingPathComponent("writing-draft.json")
        if unreadableDraft, FileManager.default.fileExists(atPath: file.path) {
            try FileManager.default.copyItem(at: file, to: store.root.appendingPathComponent("writing-draft-unreadable-\(UUID().uuidString).json"))
            unreadableDraft = false
        }
        let draft = Draft(retainedEditor ?? editorSession())
        try JSONEncoder().encode(draft).write(to: file, options: .atomic)
    }

    private func restoreDraftAfterUpdate() {
        guard let store else { return }
        let file = store.root.appendingPathComponent("writing-draft.json")
        guard FileManager.default.fileExists(atPath: file.path) else { return }
        do {
            let draft = try JSONDecoder().decode(Draft.self, from: Data(contentsOf: file))
            source = draft.source; result = draft.result; instruction = draft.instruction
            chosenActionID = draft.chosenActionID; contextTitle = draft.contextTitle; saved = draft.saved
            showChanges = draft.showChanges; editorVisible = draft.visible; jobID = draft.jobID
            original = draft.original; resultSource = draft.resultSource; resultModelName = draft.resultModelName
            resultAction = draft.resultAction; snapshot = nil
        } catch { unreadableDraft = true; self.error = "Could not restore the writing draft. Its file has been kept." }
    }

    func invokeSelection() {
        guard !busy, !replacing, automaticWork == nil else { return }
        captureWork?.cancel()
        let id = UUID(); captureGeneration = id
        captureWork = Task {
            do {
                let selected = try await selectionService.capture()
                try Task.checkCancellation()
                guard captureGeneration == id, canGenerate() else { return }
                present(.init(text: selected.text, title: "Selected text", snapshot: selected))
            } catch is CancellationError { }
            catch {
                guard captureGeneration == id, canGenerate() else { return }
                present(.init(text: "", title: "Writing tools", error: error.localizedDescription))
            }
        }
    }

    func afterDictation(_ text: String, target: TextSelectionSnapshot?) {
        guard settings.showAfterDictation, !text.isEmpty else { return }
        // Dictation may have only posted Cmd-V into this editor. Keep its field alive and focused
        // until that event lands; the inline writing actions are already available here.
        guard !(editorVisible && !panelSessionActive && isOwnAppFrontmost()) else { return }
        present(.init(text: text, title: "Just dictated", snapshot: target))
    }

    func openEditor() {
        guard !replacing else { return }
        invalidateCapture()
        pendingPanel = nil
        restoreEditor()
        panel?.hide()
        editorVisible = true
    }

    func showLibrary() {
        if panelSessionActive { dismiss() }
        editorVisible = false
    }

    func newDraft() {
        guard !replacing else { return }
        pendingPanel = nil
        restoreEditor()
        guard prepare(text: "", title: "Writing tools") else { return }
        openEditor()
    }

    func openTranscript(_ job: TranscriptionJob, actionID: String? = nil) {
        guard !replacing, let store else { return }
        pendingPanel = nil
        restoreEditor()
        guard prepare(text: store.transcriptText(job), title: job.title, jobID: job.id) else { return }
        openEditor()
        if let actionID { run(settings.action(id: actionID)) }
    }

    func openServiceText(_ text: String) {
        present(.init(text: text, title: "Selected text"))
    }

    @discardableResult
    private func prepare(text: String, title: String, snapshot: TextSelectionSnapshot? = nil, jobID: UUID? = nil) -> Bool {
        guard !replacing, !shuttingDown else { return false }
        invalidateCapture()
        cancel()
        source = text; original = text; result = ""; resultSource = ""; instruction = ""
        contextTitle = title; self.snapshot = snapshot; self.jobID = jobID
        chosenActionID = "grammar"; saved = false; error = nil; resultAction = nil
        return true
    }

    private func invalidateCapture() {
        captureGeneration = UUID(); captureWork?.cancel(); captureWork = nil
    }

    private func editorSession() -> EditingSession {
        .init(source: source, result: result, instruction: instruction, chosenActionID: chosenActionID,
              contextTitle: contextTitle, saved: saved, error: error, showChanges: showChanges,
              visible: editorVisible, snapshot: snapshot, jobID: jobID, original: original,
              resultSource: resultSource, resultModelName: resultModelName, resultAction: resultAction)
    }

    private func restoreEditor() {
        guard panelSessionActive, let retainedEditor else { return }
        cancel()
        panel?.hide()
        source = retainedEditor.source; result = retainedEditor.result; instruction = retainedEditor.instruction
        chosenActionID = retainedEditor.chosenActionID; contextTitle = retainedEditor.contextTitle
        saved = retainedEditor.saved; error = retainedEditor.error; showChanges = retainedEditor.showChanges
        editorVisible = retainedEditor.visible; snapshot = retainedEditor.snapshot; jobID = retainedEditor.jobID
        original = retainedEditor.original; resultSource = retainedEditor.resultSource
        resultModelName = retainedEditor.resultModelName; resultAction = retainedEditor.resultAction
        self.retainedEditor = nil; panelSessionActive = false
    }

    private func present(_ request: PanelRequest) {
        guard !shuttingDown else { return }
        if replacing { pendingPanel = request; return }
        if !panelSessionActive {
            retainedEditor = editorSession()
            panelSessionActive = true
            editorVisible = false
        }
        guard prepare(text: request.text, title: request.title, snapshot: request.snapshot) else { return }
        error = request.error
        showPanel(at: request.snapshot?.rect)
    }

    private func presentPendingPanel() {
        guard !replacing, !shuttingDown, canGenerate(), let pendingPanel else { return }
        self.pendingPanel = nil
        present(pendingPanel)
    }

    private func showPanel(at rect: NSRect?) {
        guard presentsPanels else { return }
        if panel == nil { panel = WritingPanelController(controller: self) }
        panel?.show(selection: rect)
    }

    func run(_ action: TextAction? = nil) {
        guard !busy, !replacing, hasSource else { return }
        guard automaticWork == nil else { error = "A note summary is in progress. Try again after it finishes."; return }
        guard canGenerate() else { error = "Finish recording or dictating before using writing tools."; return }
        let selected = action ?? self.action
        chosenActionID = selected.id
        showChanges = !selected.isSummary && selected.id != "organize"
        let model = self.model
        guard models.isInstalled(model) else {
            error = "Download \(model.name) in Settings, Models, Text editing first."
            return
        }
        let text = source, detail = instruction, style = stylePrompt, context = settings.contextMode
        let id = UUID(); generation = id
        busy = true; error = nil; result = ""; saved = false
        work = Task { [weak self] in
            guard let self else { return }
            defer {
                if self.generation == id { self.busy = false; self.work = nil; self.processAutomaticNotes() }
            }
            do {
                let revised = try await self.engine.generate(text: text, action: selected, instruction: detail, style: style,
                                                             model: model, file: self.models.location(for: model), context: context)
                try Task.checkCancellation()
                guard self.generation == id, self.source == text else { return }
                self.result = revised
                self.resultSource = text; self.resultModelName = model.name; self.resultAction = selected
            } catch is CancellationError { }
            catch { if self.generation == id { self.error = error.localizedDescription } }
        }
    }

    private var stylePrompt: String {
        let examples = settings.styleExamples.suffix(3).map { String($0.prefix(600)) }
        return settings.style + (examples.isEmpty ? "" : "\nApproved examples:\n" + examples.joined(separator: "\n"))
    }

    func cancel() {
        generation = UUID()
        if work != nil { work?.cancel(); engine.unload() }
        work = nil; busy = false
        // A canceled manual task cannot resume queued summaries from its generation-guarded defer.
        // Defer this until navigation/capture has applied its new state or started the next action.
        Task { @MainActor [weak self] in self?.processAutomaticNotes() }
    }

    func dismiss() {
        invalidateCapture()
        pendingPanel = nil
        replaceWork?.cancel()
        cancel(); panel?.hide()
        restoreEditor()
        processAutomaticNotes()
    }

    func suspendForCapture() {
        dismiss(); automaticWork?.cancel(); engine.unload()
    }

    func replace() {
        guard !replacing, canReplace, let snapshot else { return }
        replacing = true; error = nil
        let text = result
        let id = generation
        panel?.hide()
        replaceWork = Task {
            defer {
                replacing = false; replaceWork = nil
                presentPendingPanel()
            }
            do {
                let confirmed = try await selectionService.replace(snapshot, with: text)
                try Task.checkCancellation()
                guard generation == id else { return }
                if confirmed {
                    self.snapshot = nil; panel?.hide()
                    restoreEditor()
                }
                else {
                    self.snapshot = nil
                    error = "The editor did not confirm the replacement. Check its text before trying again."
                    showPanel(at: snapshot.rect)
                }
            } catch is CancellationError { }
            catch {
                guard !Task.isCancelled, generation == id else { return }
                self.error = error.localizedDescription; showPanel(at: snapshot.rect)
            }
        }
    }

    func saveVersion() {
        guard canSave, let jobID, let resultAction, let store else { return }
        do {
            try store.saveTextRevision(.init(actionID: resultAction.id, title: resultAction.title, text: result,
                                            modelName: resultModelName), for: jobID, original: original)
            saved = true
        } catch { self.error = error.localizedDescription }
    }

    func copyResult() {
        let text = result.isEmpty ? source : result
        NSPasteboard.general.prepareForNewContents(with: .currentHostOnly)
        NSPasteboard.general.setString(text, forType: .string)
    }

    func exportResult() {
        guard !result.isEmpty else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText]
        panel.nameFieldStringValue = "\(resultAction?.title ?? "Revision").txt"
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            do { try self?.result.write(to: url, atomically: true, encoding: .utf8) }
            catch { self?.error = error.localizedDescription }
        }
    }

    func rememberWording() {
        guard !result.isEmpty else { return }
        settings.rememberStyle(result)
    }

    func noteFinished(_ job: TranscriptionJob) {
        guard settings.autoSummarizeNotes, !job.transcript.isEmpty else { return }
        pendingNotes.append(job.id)
        processAutomaticNotes()
    }

    private func processAutomaticNotes() {
        guard settings.autoSummarizeNotes else { pendingNotes.removeAll(); return }
        guard !shuttingDown, !busy, automaticWork == nil, !pendingNotes.isEmpty, canGenerate(), let store else { return }
        let id = pendingNotes.removeFirst()
        guard let job = store.jobs.first(where: { $0.id == id }) else { processAutomaticNotes(); return }
        let text = store.transcriptText(job), model = self.model, summary = settings.action(id: "summary") ?? TextAction.defaults.first { $0.id == "summary" }!, style = stylePrompt, context = settings.contextMode
        guard models.isInstalled(model) else { store.error = "The note was saved. Download \(model.name) in Settings, Models to create its summary."; processAutomaticNotes(); return }
        processingNotes.insert(id)
        automaticWork = Task { [weak self] in
            guard let self else { return }
            defer { self.processingNotes.remove(id); self.automaticWork = nil; self.processAutomaticNotes() }
            do {
                let result = try await self.engine.generate(text: text, action: summary, style: style,
                                                           model: model, file: self.models.location(for: model), context: context)
                try Task.checkCancellation()
                try store.saveTextRevision(.init(actionID: summary.id, title: summary.title, text: result, modelName: model.name),
                                           for: id, original: text)
            } catch is CancellationError { if !self.shuttingDown { self.pendingNotes.insert(id, at: 0) } }
            catch {
                let failure = error as NSError
                if Task.isCancelled || (failure.domain == NSURLErrorDomain && failure.code == NSURLErrorCancelled) {
                    if !self.shuttingDown { self.pendingNotes.insert(id, at: 0) }
                } else { store.error = "The note was saved, but its summary failed. \(error.localizedDescription)" }
            }
        }
    }

    func shutdown() {
        shuttingDown = true
        pendingPanel = nil
        captureWork?.cancel(); replaceWork?.cancel()
        cancel(); automaticWork?.cancel(); automaticWork = nil; pendingNotes.removeAll()
        shortcut.stop(); panel?.hide(); engine.unload(); models.cancelDownload()
    }

    func observeCapture(recorder: NoteRecorder, dictation: DictationController) {
        recorder.$state.dropFirst().sink { [weak self] state in
            if LiveNote.isActive(state) { self?.suspendForCapture() }
            else { Task { @MainActor [weak self] in self?.presentPendingPanel(); self?.processAutomaticNotes() } }
        }.store(in: &bindings)
        dictation.$state.dropFirst().sink { [weak self] state in
            if state == .idle { Task { @MainActor [weak self] in self?.presentPendingPanel(); self?.processAutomaticNotes() } }
        }.store(in: &bindings)
    }
}
