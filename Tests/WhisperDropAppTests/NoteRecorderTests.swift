import XCTest
import WhisperDropCore
@testable import WhisperDrop

final class NoteRecorderTests: XCTestCase {
    func testLanguageTableMatchesWhisperCodesAndNames() {
        XCTAssertEqual(NoteLanguage.entries.count, 100)
        XCTAssertEqual(Set(NoteLanguage.entries.map(\.code)).count, 100)
        XCTAssertEqual(NoteLanguage.whisperCode(for: "english"), "en")
        XCTAssertEqual(NoteLanguage.whisperCode(for: "EN"), "en")
        XCTAssertEqual(NoteLanguage.whisperCode(for: "English"), "en")
        XCTAssertEqual(NoteLanguage.whisperCode(for: "haitian creole"), "ht")
        XCTAssertEqual(NoteLanguage.whisperCode(for: "cantonese"), "yue")
        XCTAssertEqual(NoteLanguage.whisperCode(for: "yue"), "yue")
        XCTAssertEqual(NoteLanguage.whisperCode(for: "  Italian "), "it")
        XCTAssertNil(NoteLanguage.whisperCode(for: "auto"))
        XCTAssertNil(NoteLanguage.whisperCode(for: "  "))
        XCTAssertNil(NoteLanguage.whisperCode(for: "klingon"))
        XCTAssertTrue(NoteLanguage.isAuto(" Auto "))
        XCTAssertFalse(NoteLanguage.isAuto("en"))
        XCTAssertEqual(NoteLanguage.requestCode(setting: "auto", pinned: nil), "auto")
        XCTAssertEqual(NoteLanguage.requestCode(setting: " Auto ", pinned: "it"), "it")
        XCTAssertEqual(NoteLanguage.requestCode(setting: "Italian", pinned: "en"), "it")
    }

    func testPromptTailAndShortChunks() {
        XCTAssertEqual(NotePrompt.tail("  hello  "), "hello")
        XCTAssertEqual(NotePrompt.tail(String(repeating: "a", count: 200)).count, 200)
        let long = "é" + String(repeating: "a", count: 200)
        XCTAssertEqual(NotePrompt.tail(long), String(repeating: "a", count: 200))
        XCTAssertNil(NotePrompt.prompt(previousText: "hello", chunkDuration: 1.99))
        XCTAssertEqual(NotePrompt.prompt(previousText: "hello", chunkDuration: 2), "hello")
        XCTAssertNil(NotePrompt.prompt(previousText: "   ", chunkDuration: 30))
        XCTAssertEqual(NotePrompt.prompt(previousText: "Prior words", chunkDuration: 30, vocabulary: "  Convex set, objective function  "), "Convex set, objective function")
        XCTAssertEqual(NotePrompt.prompt(previousText: "Prior words", chunkDuration: 30, vocabulary: String(repeating: "a", count: 450))?.count, 400)
        XCTAssertNil(NotePrompt.prompt(previousText: String(repeating: "In operazione di rispetto. ", count: 10), chunkDuration: 60))
        XCTAssertEqual(NoteClock.seconds(.seconds(1) + .milliseconds(500)), 1.5, accuracy: 0.000_001)
    }

    func testQueuePopsEarliestStartThenSequence() {
        var queue = [
            NoteQueuedChunk(sequence: 0, stream: .microphone, chunk: AudioChunk(start: 5, samples: [0.2], hasSpeech: true)),
            NoteQueuedChunk(sequence: 1, stream: .system, chunk: AudioChunk(start: 1, samples: [0.2], hasSpeech: true)),
            NoteQueuedChunk(sequence: 2, stream: .microphone, chunk: AudioChunk(start: 1, samples: [0.2], hasSpeech: true))
        ]
        XCTAssertEqual(NoteQueue.popNext(&queue)?.sequence, 1)
        XCTAssertEqual(NoteQueue.popNext(&queue)?.sequence, 2)
        XCTAssertEqual(NoteQueue.popNext(&queue)?.sequence, 0)
        XCTAssertNil(NoteQueue.popNext(&queue))
    }

    func testSpeakerLabelsRequireBothStreams() {
        XCTAssertEqual(NoteSpeakers.label(stream: .microphone, bothLive: true), .you)
        XCTAssertEqual(NoteSpeakers.label(stream: .system, bothLive: true), .others)
        XCTAssertNil(NoteSpeakers.label(stream: .microphone, bothLive: false))
        XCTAssertNil(NoteSpeakers.label(stream: .system, bothLive: false))
    }

    func testAudibleSignalIgnoresSilenceAndNonFiniteSamples() {
        XCTAssertFalse(NoteAudio.containsAudibleSignal([]))
        XCTAssertFalse(NoteAudio.containsAudibleSignal([0, 0.001, -0.001]))
        XCTAssertFalse(NoteAudio.containsAudibleSignal([.nan, .infinity].filter { !$0.isInfinite }))
        XCTAssertFalse(NoteAudio.containsAudibleSignal([.nan]))
        XCTAssertTrue(NoteAudio.containsAudibleSignal([0, -0.02]))
    }

    func testTranscriptStatePinsLanguageKeepsStreamsApartAndClearsPrompt() {
        var state = NoteTranscriptState()
        state.labelingSpeakers = false
        let lecture = ServerTranscription(
            segments: [TranscriptSegment(id: 4, start: 2, end: 3, text: " Lecture line ", speaker: .you)],
            language: "english"
        )
        let published = state.accept(lecture, stream: .microphone, languageSetting: "auto")
        XCTAssertEqual(published.map(\.id), [0])
        XCTAssertNil(published[0].speaker)
        XCTAssertEqual(published[0].text, "Lecture line")
        XCTAssertNil(state.pinnedLanguage)
        XCTAssertEqual(state.prompt(for: .microphone, chunkDuration: 3), "Lecture line")
        XCTAssertNil(state.prompt(for: .system, chunkDuration: 3))

        let ignored = ServerTranscription(segments: [TranscriptSegment(id: 0, start: 4, end: 5, text: "Still English")], language: "english")
        _ = state.accept(ignored, stream: .microphone, languageSetting: "auto")
        XCTAssertEqual(state.pinnedLanguage, "en")
        XCTAssertEqual(state.text(for: .microphone), "Lecture line Still English")

        _ = state.accept(ServerTranscription(segments: [], language: nil), stream: .microphone, languageSetting: "auto")
        XCTAssertEqual(state.text(for: .microphone), "")
        XCTAssertEqual(state.segments.map(\.text), ["Lecture line", "Still English"])

        var both = NoteTranscriptState()
        both.labelingSpeakers = true
        _ = both.accept(
            ServerTranscription(segments: [TranscriptSegment(id: 0, start: 1, end: 2, text: "From the room")], language: nil),
            stream: .microphone,
            languageSetting: "en"
        )
        let merged = both.accept(
            ServerTranscription(segments: [TranscriptSegment(id: 7, start: 0.2, end: 0.8, text: "From the call")], language: "english"),
            stream: .system,
            languageSetting: "en"
        )
        XCTAssertNil(both.pinnedLanguage)
        XCTAssertEqual(both.text(for: .microphone), "From the room")
        XCTAssertEqual(both.text(for: .system), "From the call")
        XCTAssertEqual(merged.map(\.speaker), TranscriptMerger.merge(you: both.micLines, others: both.systemLines).map(\.speaker))
        XCTAssertEqual(merged.map(\.text), ["From the call", "From the room"])
        XCTAssertEqual(merged.map(\.speaker), [.others, .you])
    }

    func testJobConstruction() {
        let zone = TimeZone(secondsFromGMT: 0)!
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let recordedAt = calendar.date(from: DateComponents(timeZone: zone, year: 2026, month: 9, day: 29, hour: 16, minute: 18))!
        let folder = URL(fileURLWithPath: "/tmp/notes/example")
        let lines = [TranscriptSegment(id: 0, start: 1, end: 2, text: "Hello", speaker: .you)]

        let named = NoteJobs.make(
            folder: folder, customTitle: "  Standup  ", recordedAt: recordedAt, segments: lines,
            modelName: "Turbo", duration: 12.5, keepAudio: true, detectedSpeech: true,
            transcriptionWarning: nil, timeZone: zone
        )
        XCTAssertEqual(named.title, "Standup")
        XCTAssertEqual(named.kind, .note)
        XCTAssertEqual(named.status, .completed)
        XCTAssertEqual(named.source, folder)
        XCTAssertEqual(named.audioFile, folder)
        XCTAssertEqual(named.modelName, "Turbo")
        XCTAssertEqual(named.duration, 12.5)
        XCTAssertEqual(named.created, recordedAt)
        XCTAssertEqual(named.transcript, TranscriptOutput.labeledText(lines))
        XCTAssertNil(named.error)

        let untitled = NoteJobs.make(
            folder: folder, customTitle: "  ", recordedAt: recordedAt, segments: [],
            modelName: "Turbo", duration: 3, keepAudio: false, detectedSpeech: false,
            transcriptionWarning: nil, timeZone: zone
        )
        XCTAssertEqual(untitled.title, "Note Sep 29, 2026, 4:18 PM")
        XCTAssertNil(untitled.audioFile)
        XCTAssertEqual(untitled.transcript, "")
        XCTAssertEqual(untitled.error, "No speech was detected.")

        let skipped = NoteJobs.make(
            folder: folder, customTitle: "Standup", recordedAt: recordedAt, segments: [],
            modelName: "Turbo", duration: 3, keepAudio: false, detectedSpeech: true,
            transcriptionWarning: "A part of the recording could not be transcribed and was skipped.",
            timeZone: zone
        )
        XCTAssertEqual(skipped.error, "A part of the recording could not be transcribed and was skipped.")
    }

    func testForcedCutDefersWholeBoundaryWordAndRemovesOverlap() {
        var state = NoteTranscriptState()
        let first = TranscriptSegment(id: 0, start: 56, end: 60, text: "The  national\ncommunity",
            words: [TranscriptWord(start: 56, end: 57, text: "The"),
                    TranscriptWord(start: 57, end: 58.5, text: "  national"),
                    TranscriptWord(start: 58.5, end: 60, text: " community")])
        let chunk = AudioChunk(start: 0, samples: [], hasSpeech: true, stableUntil: 59)
        _ = state.accept(ServerTranscription(segments: [first], language: "italian"), stream: .microphone, languageSetting: "auto", chunk: chunk)
        XCTAssertEqual(state.segments.map(\.text), ["The  national"])
        let next = TranscriptSegment(id: 0, start: 58, end: 62, text: "national community speaks.",
            words: [TranscriptWord(start: 58, end: 58.5, text: "national"),
                    TranscriptWord(start: 58.5, end: 60, text: " community"),
                    TranscriptWord(start: 60, end: 62, text: " speaks.")])
        _ = state.accept(ServerTranscription(segments: [next], language: "italian"), stream: .microphone, languageSetting: "auto",
                         chunk: AudioChunk(start: 58, samples: [], hasSpeech: true, stableUntil: 64))
        XCTAssertEqual(TranscriptOutput.labeledText(state.segments), "The  national community speaks.")
        XCTAssertEqual(state.pinnedLanguage, "it")
    }

    func testNoteKeepsRealRepeatedSentencesAndDoesNotPinSilence() {
        var state = NoteTranscriptState()
        _ = state.accept(ServerTranscription(segments: [], language: "english"), stream: .microphone, languageSetting: "auto")
        XCTAssertNil(state.pinnedLanguage)
        let result = ServerTranscription(segments: [
            TranscriptSegment(id: 0, start: 0, end: 2, text: "The constraint applies to every point."),
            TranscriptSegment(id: 1, start: 2.1, end: 4, text: "The constraint applies to every point.")], language: "italian")
        _ = state.accept(result, stream: .microphone, languageSetting: "auto")
        XCTAssertEqual(state.segments.count, 2)
        XCTAssertNil(state.pinnedLanguage)
    }

    func testWarningSurvivesInPartialCompletedNote() {
        let job = NoteJobs.make(folder: URL(fileURLWithPath: "/tmp/example"), customTitle: "Example", recordedAt: Date(),
            segments: [TranscriptSegment(id: 0, start: 0, end: 1, text: "Some speech.")], modelName: "Turbo", duration: 60,
            keepAudio: true, detectedSpeech: true, transcriptionWarning: "One chunk failed.")
        XCTAssertEqual(job.error, "One chunk failed.")
    }

    func testRenumberSortsByStartThenPreviousId() {
        let result = NoteJobs.renumber([
            TranscriptSegment(id: 2, start: 1, end: 2, text: "B"),
            TranscriptSegment(id: 1, start: 1, end: 2, text: "A"),
            TranscriptSegment(id: 0, start: 0, end: 1, text: "Z")
        ])
        XCTAssertEqual(result.map(\.text), ["Z", "A", "B"])
        XCTAssertEqual(result.map(\.id), [0, 1, 2])
    }
}

final class NoteLivePreviewTests: XCTestCase {
    func testPreviewSkipsWordsAlreadyCommittedFromTheOverlap() {
        let words = [TranscriptWord(start: 10, end: 10.4, text: " già"), TranscriptWord(start: 10.5, end: 11, text: " detto"),
                     TranscriptWord(start: 12, end: 12.5, text: " nuove"), TranscriptWord(start: 12.6, end: 13, text: " parole")]
        let result = ServerTranscription(segments: [TranscriptSegment(id: 0, start: 10, end: 13, text: "già detto nuove parole", words: words)], language: "it")
        var live = LiveText(start: 10)
        live.accept(result.timedWords, window: 10..<13)
        XCTAssertEqual(live.text, "già detto nuove parole")
        live.discard(through: 11.5)
        XCTAssertEqual(live.text, "nuove parole")
    }
}
