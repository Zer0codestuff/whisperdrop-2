import XCTest
import WhisperDropCore
@testable import WhisperDrop

@MainActor
final class SavedLibraryTests: XCTestCase {
    private var folder: URL!
    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("WhisperDrop-storage-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: folder) }

    private func write(_ data: String, at url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(data.utf8).write(to: url)
    }

    func testLegacyMigrationSeparatesAudioAndTranscriptsAndCommitsReferences() throws {
        let root = folder.appendingPathComponent("AppData")
        let note = root.appendingPathComponent("Notes/note-id", isDirectory: true)
        try write("original audio", at: note.appendingPathComponent("you.caf"))
        try write("[]", at: note.appendingPathComponent("transcript.json"))
        try write("archived text", at: root.appendingPathComponent("Transcripts/file-id/transcript.txt"))
        var job = TranscriptionJob(source: note)
        job.kind = .note; job.status = .completed; job.audioFile = note
        job.segments = [TranscriptSegment(id: 0, start: 0, end: 1, text: "A real sentence.")]
        try JSONEncoder().encode([job]).write(to: root.appendingPathComponent("history.json"))
        let store = AppStore(root: root)
        XCTAssertNil(store.error)
        XCTAssertEqual(store.jobs[0].source.path, root.appendingPathComponent("Saved/Transcripts/note-id").path)
        XCTAssertEqual(store.jobs[0].audioFile?.path, root.appendingPathComponent("Saved/Audio/note-id").path)
        XCTAssertEqual(try String(contentsOf: store.audioFolder.appendingPathComponent("note-id/you.caf")), "original audio")
        XCTAssertEqual(try String(contentsOf: store.outputFolder.appendingPathComponent("note-id/transcript.txt")), "A real sentence.")
        XCTAssertEqual(try String(contentsOf: store.outputFolder.appendingPathComponent("note-id/transcript.json")), "[]")
        XCTAssertEqual(try String(contentsOf: store.outputFolder.appendingPathComponent("file-id/transcript.txt")), "archived text")
        XCTAssertFalse(FileManager.default.fileExists(atPath: note.path))
        let snapshot = try JSONDecoder().decode(LibrarySnapshot.self, from: Data(contentsOf: root.appendingPathComponent("history.json")))
        XCTAssertEqual(snapshot.jobs[0].source, store.jobs[0].source)
        let reopened = AppStore(root: root)
        XCTAssertEqual(reopened.jobs.count, 1)
        XCTAssertEqual(reopened.jobs[0].audioFile, store.jobs[0].audioFile)
    }

    func testCopiesStayAtSourceUntilCommitAndCollisionDoesNotOverwrite() throws {
        let root = folder.appendingPathComponent("AppData")
        let original = root.appendingPathComponent("Notes/note/you.caf")
        let target = folder.appendingPathComponent("Documents")
        let copy = target.appendingPathComponent("Audio/note/you.caf")
        try write("original", at: original)
        let plan = try SavedLibrary.migrate(jobs: [], from: nil, legacyRoot: root, to: target)
        XCTAssertEqual(try Data(contentsOf: original), try Data(contentsOf: copy))
        try write("changed destination", at: copy)
        XCTAssertThrowsError(try plan.finish())
        XCTAssertTrue(FileManager.default.fileExists(atPath: original.path))
        XCTAssertThrowsError(try SavedLibrary.migrate(jobs: [], from: nil, legacyRoot: root, to: target))
        XCTAssertEqual(try String(contentsOf: copy), "changed destination")
    }

    func testCustomFolderMovesExistingFilesAndPersistsAfterRestart() async throws {
        let root = folder.appendingPathComponent("AppData")
        let store = AppStore(root: root)
        let note = store.audioFolder.appendingPathComponent("note", isDirectory: true)
        let transcript = store.outputFolder.appendingPathComponent("note", isDirectory: true)
        try write("untouched audio", at: note.appendingPathComponent("you.caf"))
        var job = TranscriptionJob(source: transcript)
        job.kind = .note; job.status = .completed; job.audioFile = note
        job.segments = [TranscriptSegment(id: 0, start: 0, end: 1, text: "Saved words.")]
        store.addNote(job)
        let destination = folder.appendingPathComponent("Chosen")
        await store.changeSavedFolder(to: destination)
        XCTAssertNil(store.error)
        XCTAssertEqual(store.jobs[0].audioFile?.path, destination.appendingPathComponent("Audio/note").path)
        XCTAssertFalse(FileManager.default.fileExists(atPath: note.path))
        XCTAssertEqual(try String(contentsOf: destination.appendingPathComponent("Audio/note/you.caf")), "untouched audio")
        let reopened = AppStore(root: root)
        XCTAssertNil(reopened.error)
        XCTAssertEqual(reopened.savedFolder.path, destination.path)
        XCTAssertEqual(reopened.jobs[0].source.path, destination.appendingPathComponent("Transcripts/note").path)
    }

    func testNestedDestinationsAndMoveDuringRecordingAreRejected() async throws {
        let store = AppStore(root: folder.appendingPathComponent("AppData"))
        let old = store.savedFolder
        await store.changeSavedFolder(to: old.appendingPathComponent("Nested"))
        XCTAssertEqual(store.savedFolder, old)
        XCTAssertNotNil(store.error)
        store.error = nil
        store.canMoveSavedFiles = { false }
        await store.changeSavedFolder(to: folder.appendingPathComponent("Chosen"))
        XCTAssertEqual(store.savedFolder, old)
        XCTAssertFalse(store.movingSavedFiles)
        XCTAssertNil(store.error)
    }

    func testRestartFinishesAnInterruptedMoveAndKeepsUnrelatedFiles() throws {
        let root = folder.appendingPathComponent("AppData")
        let old = root.appendingPathComponent("Saved")
        let target = folder.appendingPathComponent("Chosen")
        try write("audio", at: old.appendingPathComponent("Audio/note/you.caf"))
        try write("unrelated", at: old.appendingPathComponent("my-file.txt"))
        let job = TranscriptionJob(source: old.appendingPathComponent("Audio/note/you.caf"))
        let migration = try SavedLibrary.migrate(jobs: [job], from: old, legacyRoot: nil, to: target)
        try JSONEncoder().encode(LibrarySnapshot(savedFolder: target, jobs: migration.jobs, pendingPreviousFolder: old))
            .write(to: root.appendingPathComponent("history.json"))
        let reopened = AppStore(root: root)
        XCTAssertNil(reopened.error)
        XCTAssertFalse(FileManager.default.fileExists(atPath: old.appendingPathComponent("Audio/note/you.caf").path))
        XCTAssertEqual(try String(contentsOf: old.appendingPathComponent("my-file.txt")), "unrelated")
        XCTAssertEqual(try String(contentsOf: reopened.jobs[0].source), "audio")
        let committed = try JSONDecoder().decode(LibrarySnapshot.self, from: Data(contentsOf: root.appendingPathComponent("history.json")))
        XCTAssertNil(committed.pendingPreviousFolder)
    }

    func testUnreadableHistoryIsNotReplacedByAnEmptyLibrary() throws {
        let root = folder.appendingPathComponent("AppData")
        let history = root.appendingPathComponent("history.json")
        try write("broken history", at: history)
        let store = AppStore(root: root)
        XCTAssertNotNil(store.error)
        store.save()
        XCTAssertEqual(try String(contentsOf: history), "broken history")
        XCTAssertFalse(store.canRecordNotes)
    }

    func testFailedCleanupKeepsItsPreviousFolderAcrossLaterSaves() throws {
        let root = folder.appendingPathComponent("AppData")
        let old = root.appendingPathComponent("Saved")
        let target = folder.appendingPathComponent("Chosen")
        try write("original", at: old.appendingPathComponent("Audio/note/you.caf"))
        try write("conflicting copy", at: target.appendingPathComponent("Audio/note/you.caf"))
        try JSONEncoder().encode(LibrarySnapshot(savedFolder: target, jobs: [], pendingPreviousFolder: old))
            .write(to: root.appendingPathComponent("history.json"))
        let store = AppStore(root: root)
        XCTAssertNotNil(store.error)
        store.save()
        let saved = try JSONDecoder().decode(LibrarySnapshot.self, from: Data(contentsOf: root.appendingPathComponent("history.json")))
        XCTAssertEqual(saved.pendingPreviousFolder, old)
        XCTAssertEqual(try String(contentsOf: old.appendingPathComponent("Audio/note/you.caf")), "original")
    }
}
