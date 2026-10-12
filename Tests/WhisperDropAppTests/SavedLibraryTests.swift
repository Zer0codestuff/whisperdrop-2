import AVFoundation
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
        XCTAssertEqual(try String(contentsOf: destination.appendingPathComponent("Audio/note/note.caf")), "untouched audio")
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

    func testRenameMovesFoldersAndRecordingToTheNewNameAndPersists() throws {
        let root = folder.appendingPathComponent("AppData")
        let store = AppStore(root: root)
        try write("original recording", at: store.audioFolder.appendingPathComponent("note/you.m4a"))
        try write("mine", at: store.audioFolder.appendingPathComponent("note/my-cut.mp3"))
        var job = TranscriptionJob(source: store.outputFolder.appendingPathComponent("note", isDirectory: true), title: "Old: title")
        job.kind = .note; job.status = .completed; job.audioFile = store.audioFolder.appendingPathComponent("note", isDirectory: true)
        job.segments = [TranscriptSegment(id: 0, start: 0, end: 1, text: "Saved words.")]
        job.transcript = "Saved words."
        store.addNote(job)
        XCTAssertNil(store.error)
        XCTAssertEqual(try String(contentsOf: store.audioFolder.appendingPathComponent("Old. title/Old. title.m4a")), "original recording")
        XCTAssertEqual(store.current?.source.path, store.outputFolder.appendingPathComponent("Old. title").path)

        try store.renameNote(job.id, to: "  Lesson 1  ")
        XCTAssertEqual(store.current?.title, "Lesson 1")
        XCTAssertEqual(store.current?.id, job.id)
        XCTAssertEqual(store.current?.audioFile?.path, store.audioFolder.appendingPathComponent("Lesson 1").path)
        XCTAssertEqual(store.current?.segments.map(\.text), job.segments.map(\.text))
        XCTAssertEqual(try String(contentsOf: store.audioFolder.appendingPathComponent("Lesson 1/Lesson 1.m4a")), "original recording")
        XCTAssertEqual(try String(contentsOf: store.audioFolder.appendingPathComponent("Lesson 1/my-cut.mp3")), "mine")
        XCTAssertEqual(try String(contentsOf: store.outputFolder.appendingPathComponent("Lesson 1/transcript.txt")), "Saved words.")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: store.audioFolder.path), ["Lesson 1"])
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: store.outputFolder.path), ["Lesson 1"])
        let saved = try JSONDecoder().decode(LibrarySnapshot.self, from: Data(contentsOf: root.appendingPathComponent("history.json")))
        XCTAssertNil(saved.pendingRenames)
        let reopened = AppStore(root: root)
        XCTAssertNil(reopened.error)
        XCTAssertEqual(reopened.jobs.first?.title, "Lesson 1")
        XCTAssertEqual(reopened.jobs.first?.audioFile, store.current?.audioFile)
        XCTAssertEqual(reopened.jobs.first?.transcript, job.transcript)
    }

    func testRenameWithoutAudioAndDuplicateTitlesKeepSeparateNotes() throws {
        let store = AppStore(root: folder.appendingPathComponent("AppData"))
        var first = TranscriptionJob(source: store.outputFolder.appendingPathComponent("first", isDirectory: true), title: "First")
        first.kind = .note; first.status = .completed
        var second = first
        second.id = UUID(); second.source = store.outputFolder.appendingPathComponent("second", isDirectory: true); second.title = "Lesson 1"
        store.addNote(first); store.addNote(second)
        try store.renameNote(first.id, to: "Lesson 1")
        XCTAssertEqual(store.jobs.map(\.title), ["Lesson 1", "Lesson 1"])
        XCTAssertEqual(Set(store.jobs.map(\.id)).count, 2)
        XCTAssertEqual(store.jobs.map(\.source.lastPathComponent), ["Lesson 1", "Lesson 1 2"])
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: store.outputFolder.path).sorted(), ["Lesson 1", "Lesson 1 2"])
        XCTAssertNil(store.jobs.last?.audioFile)
        XCTAssertThrowsError(try store.renameNote(first.id, to: " \n\t "))
        XCTAssertEqual(store.jobs.last?.title, "Lesson 1")
        var file = TranscriptionJob(source: folder.appendingPathComponent("input.wav"))
        file.status = .completed
        store.jobs.append(file)
        XCTAssertThrowsError(try store.renameNote(file.id, to: "A file"))
        XCTAssertEqual(store.jobs.last?.title, file.title)
    }

    func testLaunchNamesIdentifierFoldersAndFinishesAnInterruptedRename() throws {
        let root = folder.appendingPathComponent("AppData")
        let saved = root.appendingPathComponent("Saved")
        let id = UUID().uuidString
        try write("mic", at: saved.appendingPathComponent("Audio/\(id)/you.caf"))
        try write("call", at: saved.appendingPathComponent("Audio/\(id)/others.caf"))
        try write("[]", at: saved.appendingPathComponent("Transcripts/\(id)/transcript.json"))
        var note = TranscriptionJob(source: saved.appendingPathComponent("Transcripts/\(id)", isDirectory: true), title: "DS, 6 Oct 2026, 17:05")
        note.kind = .note; note.status = .completed; note.audioFile = saved.appendingPathComponent("Audio/\(id)", isDirectory: true)
        // A rename that was committed but never reached the disk.
        try write("interrupted", at: saved.appendingPathComponent("Audio/Before/Before.m4a"))
        var moved = TranscriptionJob(source: saved.appendingPathComponent("Transcripts/After", isDirectory: true), title: "After")
        moved.kind = .note; moved.status = .completed; moved.audioFile = saved.appendingPathComponent("Audio/After", isDirectory: true)
        let pending = SavedLibrary.Rename(from: saved.appendingPathComponent("Audio/Before/Before.m4a"), to: saved.appendingPathComponent("Audio/Before/After.m4a"))
        let folderRename = SavedLibrary.Rename(from: saved.appendingPathComponent("Audio/Before"), to: saved.appendingPathComponent("Audio/After"))
        try JSONEncoder().encode(LibrarySnapshot(savedFolder: saved, jobs: [note, moved], pendingRenames: [pending, folderRename]))
            .write(to: root.appendingPathComponent("history.json"))

        let store = AppStore(root: root)
        XCTAssertNil(store.error)
        let name = "DS, 6 Oct 2026, 17.05"
        XCTAssertEqual(store.jobs[0].source.path, saved.appendingPathComponent("Transcripts/\(name)").path)
        XCTAssertEqual(try String(contentsOf: saved.appendingPathComponent("Audio/\(name)/\(name) - You.caf")), "mic")
        XCTAssertEqual(try String(contentsOf: saved.appendingPathComponent("Audio/\(name)/\(name) - Others.caf")), "call")
        XCTAssertEqual(try String(contentsOf: saved.appendingPathComponent("Audio/After/After.m4a")), "interrupted")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: saved.appendingPathComponent("Audio").path).sorted(), ["After", name])
        let committed = try JSONDecoder().decode(LibrarySnapshot.self, from: Data(contentsOf: root.appendingPathComponent("history.json")))
        XCTAssertNil(committed.pendingRenames)
        XCTAssertEqual(committed.jobs[0].audioFile, store.jobs[0].audioFile)
        XCTAssertEqual(NoteAudio.savedFiles(in: try XCTUnwrap(store.jobs[0].audioFile)).map(\.lastPathComponent), ["\(name) - Others.caf", "\(name) - You.caf"])
    }

    func testOlderRecordingsBecomeM4AAndUnreadableOnesAreKept() async throws {
        let store = AppStore(root: folder.appendingPathComponent("AppData"))
        let audio = store.audioFolder.appendingPathComponent("Lesson", isDirectory: true)
        try FileManager.default.createDirectory(at: audio, withIntermediateDirectories: true)
        let writer = try AudioFileWriter(url: audio.appendingPathComponent("you.caf"))
        let samples = (0..<160_000).map { Float(sin(Double($0) * 2 * .pi * 220 / 16_000)) * 0.3 }
        writer.append(samples)
        writer.close()
        try write("not audio", at: audio.appendingPathComponent("others.caf"))
        let original = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: audio.appendingPathComponent("you.caf").path)[.size] as? Int)
        var job = TranscriptionJob(source: store.outputFolder.appendingPathComponent("Lesson", isDirectory: true), title: "Lesson")
        job.kind = .note; job.status = .completed; job.audioFile = audio
        store.addNote(job)
        store.discardOriginal = { try FileManager.default.removeItem(at: $0) }

        await store.compressSavedAudio()
        XCTAssertFalse(store.compressingAudio)
        let compressed = audio.appendingPathComponent("Lesson - You.m4a")
        let file = try AVAudioFile(forReading: compressed)
        XCTAssertEqual(file.length, AVAudioFramePosition(samples.count))
        XCTAssertEqual(file.fileFormat.settings[AVFormatIDKey] as? UInt32, kAudioFormatMPEG4AAC)
        let size = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: compressed.path)[.size] as? Int)
        XCTAssertLessThan(size, original / 4)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: audio.path).sorted(), ["Lesson - Others.caf", "Lesson - You.m4a"])
        XCTAssertEqual(try String(contentsOf: audio.appendingPathComponent("Lesson - Others.caf")), "not audio")
    }

    func testRenameFailureKeepsThePreviousTitle() throws {
        let root = folder.appendingPathComponent("AppData")
        let store = AppStore(root: root)
        var job = TranscriptionJob(source: store.outputFolder.appendingPathComponent("note"), title: "Original")
        job.kind = .note; job.status = .completed
        store.addNote(job)
        let history = root.appendingPathComponent("history.json")
        try FileManager.default.removeItem(at: history)
        try FileManager.default.createDirectory(at: history, withIntermediateDirectories: true)
        XCTAssertThrowsError(try store.renameNote(job.id, to: "Lesson 1"))
        XCTAssertEqual(store.jobs.first?.title, "Original")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: store.outputFolder.path), ["Original"])
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
