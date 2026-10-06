import XCTest
import WhisperDropCore
@testable import WhisperDrop

@MainActor
final class TextRevisionTests: XCTestCase {
    private func fixture() throws -> (URL, AppStore, TranscriptionJob) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("writing-library-\(UUID())")
        let store = AppStore(root: root)
        var note = TranscriptionJob(source: store.outputFolder.appendingPathComponent("synthetic-note"), title: "Synthetic note")
        note.kind = .note; note.status = .completed
        note.segments = [.init(id: 0, start: 0, end: 5, text: "We will send the report on Friday.")]
        note.transcript = note.segments[0].text
        store.addNote(note)
        return (root, store, note)
    }

    func testSavedVersionSurvivesRestartWithoutChangingTranscriptOrSubtitles() throws {
        let (root, store, note) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let original = store.transcriptText(note)
        let subtitles = TranscriptOutput.subtitles(note.segments, vtt: false)
        let revision = TextRevision(actionID: "summary", title: "Summary", text: "Report due Friday.", modelName: "Synthetic model")
        try store.saveTextRevision(revision, for: note.id, original: original)
        let reopened = AppStore(root: root)
        let saved = try XCTUnwrap(reopened.jobs.first)
        XCTAssertEqual(saved.textRevisions, [revision])
        XCTAssertEqual(reopened.transcriptText(saved), original)
        XCTAssertEqual(TranscriptOutput.subtitles(saved.segments, vtt: false), subtitles)
    }

    func testChangedSourceAndFailedCommitDoNotPublishVersion() throws {
        let (root, store, note) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let revision = TextRevision(actionID: "grammar", title: "Fix grammar", text: "Revised.", modelName: "Synthetic model")
        XCTAssertThrowsError(try store.saveTextRevision(revision, for: note.id, original: "Stale text"))
        XCTAssertNil(store.jobs.first?.textRevisions)
        let history = root.appendingPathComponent("history.json")
        try FileManager.default.removeItem(at: history)
        try FileManager.default.createDirectory(at: history, withIntermediateDirectories: false)
        XCTAssertThrowsError(try store.saveTextRevision(revision, for: note.id, original: store.transcriptText(note)))
        XCTAssertNil(store.jobs.first?.textRevisions)
    }

    func testOldJobWithoutTextVersionsStillDecodes() throws {
        let (root, _, note) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(note)) as? [String: Any])
        object.removeValue(forKey: "textRevisions")
        let decoded = try JSONDecoder().decode(TranscriptionJob.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertNil(decoded.textRevisions)
        XCTAssertEqual(decoded.transcript, note.transcript)
    }
}
