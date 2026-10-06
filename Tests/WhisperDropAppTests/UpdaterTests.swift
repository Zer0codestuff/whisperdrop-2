import XCTest
import WhisperDropCore
import Sparkle
@testable import WhisperDrop

@MainActor
final class UpdaterTests: XCTestCase {
    func testNoUpdateAndCancellationAreShownAsNormalOutcomes() {
        let updater = AppUpdater()
        updater.handleUpdateError(NSError(domain: SUSparkleErrorDomain, code: Int(SUError.noUpdateError.rawValue)))
        XCTAssertEqual(updater.status, "You have the latest available version.")
        updater.handleUpdateError(NSError(domain: SUSparkleErrorDomain, code: Int(SUError.installationCanceledError.rawValue)))
        XCTAssertEqual(updater.status, "Update canceled. Your current version is unchanged.")
    }
    func testRestartWaitsForRecordingAndResumesOnlyOnce() {
        let updater = AppUpdater()
        var activity = UpdateActivity(); activity.recording = true
        var saves = 0, installs = 0
        updater.currentActivity = { activity }
        updater.prepareToRestart = { saves += 1 }
        updater.deferRestart { installs += 1 }
        XCTAssertTrue(updater.deferred); XCTAssertEqual(saves, 0); XCTAssertEqual(installs, 0)
        activity.recording = false
        updater.retryDeferredInstall(); updater.retryDeferredInstall()
        XCTAssertFalse(updater.deferred); XCTAssertEqual(saves, 1); XCTAssertEqual(installs, 1)
    }

    func testFailedDraftSavePreventsRestartUntilRetrySucceeds() {
        let updater = AppUpdater()
        var failure = true, installs = 0
        updater.prepareToRestart = { if failure { throw CocoaError(.fileWriteOutOfSpace) } }
        updater.deferRestart { installs += 1 }
        XCTAssertTrue(updater.deferred); XCTAssertEqual(installs, 0)
        XCTAssertTrue(updater.status.contains("Could not save"))
        failure = false; updater.retryDeferredInstall()
        XCTAssertEqual(installs, 1); XCTAssertFalse(updater.deferred)
    }

    func testDraftAndSuggestionSurviveRestartWithoutCrossAppReplacement() throws {
        try withStore { store, defaults in
            let first = controller(store, defaults)
            first.openEditor(); first.source = "A draft awaiting review."; first.result = "A suggestion awaiting review."
            first.instruction = "Preserve the date."; first.chosenActionID = "rewrite"; first.showChanges = false
            try first.saveDraftForUpdate(); first.shutdown()
            let restored = controller(store, defaults); defer { restored.shutdown() }
            XCTAssertEqual(restored.source, "A draft awaiting review.")
            XCTAssertEqual(restored.result, "A suggestion awaiting review.")
            XCTAssertEqual(restored.instruction, "Preserve the date.")
            XCTAssertEqual(restored.chosenActionID, "rewrite"); XCTAssertFalse(restored.showChanges)
            XCTAssertTrue(restored.editorVisible); XCTAssertFalse(restored.canReplace)
        }
    }

    func testTransientPanelCannotOverwriteTheStoredMainDraft() throws {
        try withStore { store, defaults in
            let first = controller(store, defaults); defer { first.shutdown() }
            first.openEditor(); first.source = "Keep the main editor draft."
            first.afterDictation("A transient dictation.", target: nil)
            XCTAssertTrue(first.hasOpenReviewPanel)
            try first.saveDraftForUpdate()
            let restored = controller(store, defaults); defer { restored.shutdown() }
            XCTAssertEqual(restored.source, "Keep the main editor draft.")
        }
    }

    func testUnreadableDraftIsBackedUpBeforeAReplacementIsSaved() throws {
        try withStore { store, defaults in
            let file = store.root.appendingPathComponent("writing-draft.json")
            let original = Data("unreadable but retained".utf8); try original.write(to: file)
            let writing = controller(store, defaults); defer { writing.shutdown() }
            XCTAssertNotNil(writing.error); writing.source = "The new draft."
            try writing.saveDraftForUpdate()
            let files = try FileManager.default.contentsOfDirectory(at: store.root, includingPropertiesForKeys: nil)
            let backup = try XCTUnwrap(files.first { $0.lastPathComponent.hasPrefix("writing-draft-unreadable-") })
            XCTAssertEqual(try Data(contentsOf: backup), original)
        }
    }

    private func controller(_ store: AppStore, _ defaults: UserDefaults) -> WritingController {
        WritingController(settings: WritingSettings(defaults: defaults), models: TextModelStore(folder: store.root.appendingPathComponent("TextModels")),
                          engine: TextGenerationEngine(runtime: { store.root.appendingPathComponent("unused") }, processFile: store.root.appendingPathComponent("unused.pid")), store: store,
                          defaults: defaults, presentsPanels: false)
    }
    private func withStore(_ body: (AppStore, UserDefaults) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = "WhisperDrop.UpdaterTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
        try body(AppStore(root: root), defaults)
    }
}
