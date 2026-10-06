import XCTest
import WhisperDropCore
@testable import WhisperDrop

@MainActor
final class WritingNavigationTests: XCTestCase {
    func testLibraryNavigationAndRepeatedOpeningKeepAnUnfinishedDraft() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = "WhisperDropWritingNavigation.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
        let settings = WritingSettings(defaults: defaults)
        let store = AppStore(root: root)
        let models = TextModelStore(folder: root.appendingPathComponent("TextModels"))
        let engine = TextGenerationEngine(runtime: { root.appendingPathComponent("unused-runtime") }, processFile: root.appendingPathComponent("unused.pid"))
        let controller = WritingController(settings: settings, models: models, engine: engine, store: store, defaults: defaults)
        defer { controller.shutdown() }
        XCTAssertFalse(controller.editorVisible)
        controller.openEditor()
        controller.source = "An unfinished draft."
        controller.instruction = "Keep its voice."
        controller.result = "A suggestion under review."
        controller.showLibrary()
        XCTAssertFalse(controller.editorVisible)
        controller.openEditor(); controller.openEditor()
        XCTAssertTrue(controller.editorVisible)
        XCTAssertEqual(controller.source, "An unfinished draft.")
        XCTAssertEqual(controller.instruction, "Keep its voice.")
        XCTAssertEqual(controller.result, "A suggestion under review.")
        controller.newDraft()
        XCTAssertTrue(controller.editorVisible)
        XCTAssertTrue(controller.source.isEmpty); XCTAssertTrue(controller.result.isEmpty)
    }

    func testTranscriptReviewUsesTheMainEditorAndKeepsTheOriginal() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = "WhisperDropWritingNavigation.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
        let settings = WritingSettings(defaults: defaults)
        let store = AppStore(root: root)
        let models = TextModelStore(folder: root.appendingPathComponent("TextModels"))
        let engine = TextGenerationEngine(runtime: { root.appendingPathComponent("unused-runtime") }, processFile: root.appendingPathComponent("unused.pid"))
        let controller = WritingController(settings: settings, models: models, engine: engine, store: store, defaults: defaults)
        defer { controller.shutdown() }
        var job = TranscriptionJob(source: root.appendingPathComponent("sample.wav"))
        job.status = .completed; job.transcript = "A complete transcript."
        store.jobs = [job]
        controller.openTranscript(job)
        XCTAssertTrue(controller.editorVisible)
        XCTAssertEqual(controller.source, job.transcript)
        controller.source = "An edited working copy."
        XCTAssertEqual(store.jobs.first?.transcript, "A complete transcript.")
        XCTAssertFalse(controller.canReplace)
    }

    func testDictationPanelRestoresTheUnfinishedEditorAndSuggestion() throws {
        try withController { controller, _ in
            controller.openEditor()
            controller.source = "An unfinished draft."
            controller.result = "A suggestion under review."
            controller.instruction = "Keep its voice."
            controller.chosenActionID = "natural"
            controller.showChanges = false
            controller.error = "An editor-specific message."

            controller.afterDictation("A different dictation.", target: nil)
            XCTAssertEqual(controller.source, "A different dictation.")
            XCTAssertEqual(controller.contextTitle, "Just dictated")
            XCTAssertFalse(controller.editorVisible)
            controller.dismiss()

            XCTAssertTrue(controller.editorVisible)
            XCTAssertEqual(controller.source, "An unfinished draft.")
            XCTAssertEqual(controller.result, "A suggestion under review.")
            XCTAssertEqual(controller.instruction, "Keep its voice.")
            XCTAssertEqual(controller.chosenActionID, "natural")
            XCTAssertFalse(controller.showChanges)
            XCTAssertEqual(controller.error, "An editor-specific message.")
        }
    }

    func testSelectedTextPanelDoesNotReplaceTheRetainedTranscriptWorkingCopy() throws {
        try withController { controller, store in
            var job = TranscriptionJob(source: store.root.appendingPathComponent("sample.wav"))
            job.status = .completed; job.transcript = "The saved original transcript."
            store.jobs = [job]
            controller.openTranscript(job)
            controller.source = "An unsaved transcript working copy."
            controller.result = "Its pending suggestion."
            controller.showLibrary()

            controller.openServiceText("A temporary selection from another app.")
            XCTAssertEqual(controller.source, "A temporary selection from another app.")
            controller.openServiceText("A second temporary selection.")
            controller.openEditor()

            XCTAssertTrue(controller.editorVisible)
            XCTAssertEqual(controller.source, "An unsaved transcript working copy.")
            XCTAssertEqual(controller.result, "Its pending suggestion.")
            XCTAssertEqual(controller.contextTitle, job.title)
            XCTAssertEqual(store.jobs.first?.transcript, "The saved original transcript.")
        }
    }

    func testDictatingIntoTheFrontmostInlineEditorDoesNotReplaceOrHideItsSession() throws {
        try withController(isOwnAppFrontmost: { true }) { controller, _ in
            controller.openEditor()
            controller.source = "Existing draft, followed by "
            controller.result = "A suggestion still under review."
            controller.instruction = "Preserve my examples."
            // Cmd-V may still be pending when this callback arrives.
            controller.afterDictation("the newly dictated words", target: nil)
            XCTAssertTrue(controller.editorVisible)
            XCTAssertEqual(controller.contextTitle, "Writing tools")
            XCTAssertEqual(controller.source, "Existing draft, followed by ")
            XCTAssertEqual(controller.result, "A suggestion still under review.")
            XCTAssertEqual(controller.instruction, "Preserve my examples.")
            controller.source += "the newly dictated words."
            XCTAssertEqual(controller.source, "Existing draft, followed by the newly dictated words.")
        }
    }

    func testOwnAppLibraryStillReceivesTheAutomaticDictationPanel() throws {
        try withController(isOwnAppFrontmost: { true }) { controller, _ in
            controller.openEditor()
            controller.source = "A retained draft."
            controller.showLibrary()
            controller.afterDictation("Words dictated from the library.", target: nil)
            XCTAssertFalse(controller.editorVisible)
            XCTAssertEqual(controller.contextTitle, "Just dictated")
            XCTAssertEqual(controller.source, "Words dictated from the library.")
            controller.dismiss()
            XCTAssertFalse(controller.editorVisible)
            XCTAssertEqual(controller.source, "A retained draft.")
        }
    }

    private func withController(isOwnAppFrontmost: @escaping @MainActor () -> Bool = { false },
                                _ body: (WritingController, AppStore) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = "WhisperDropWritingNavigation.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
        let settings = WritingSettings(defaults: defaults)
        let store = AppStore(root: root)
        let models = TextModelStore(folder: root.appendingPathComponent("TextModels"))
        let engine = TextGenerationEngine(runtime: { root.appendingPathComponent("unused-runtime") },
                                          processFile: root.appendingPathComponent("unused.pid"))
        let controller = WritingController(settings: settings, models: models, engine: engine, store: store,
                                           defaults: defaults, presentsPanels: false, isOwnAppFrontmost: isOwnAppFrontmost)
        defer { controller.shutdown() }
        try body(controller, store)
    }
}
