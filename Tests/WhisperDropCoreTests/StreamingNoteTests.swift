import XCTest
@testable import WhisperDropCore

final class StreamingNoteTests: XCTestCase {
    private func word(_ start: Double, _ text: String) -> TranscriptWord {
        TranscriptWord(start: start, end: start + 0.4, text: text)
    }

    func testEverySentenceIsItsOwnParagraphWithoutATimeLimit() {
        var paragraphs = SentenceParagraphs(speaker: .you)
        paragraphs.append([word(1, " Oggi"), word(1.5, " parliamo"), word(2, " di"), word(2.5, " integrali.")])
        paragraphs.append([word(3, " Partiamo"), word(80, " dalla")])
        XCTAssertEqual(paragraphs.segments.map(\.text), ["Oggi parliamo di integrali.", "Partiamo dalla"])
        paragraphs.append([word(81, " definizione!"), word(82, " Va"), word(82.5, " bene?"), word(83, " Sì")])
        let segments = paragraphs.segments
        XCTAssertEqual(segments.map(\.text), ["Oggi parliamo di integrali.", "Partiamo dalla definizione!", "Va bene?", "Sì"])
        XCTAssertEqual(segments[1].start, 3)
        XCTAssertEqual(segments[1].end, 81.4, accuracy: 1e-9)
        XCTAssertEqual(segments.map(\.speaker), [.you, .you, .you, .you])
        XCTAssertEqual(paragraphs.closed.count, 3)
        XCTAssertEqual(TranscriptOutput.paragraphs(segments, eachSentence: true).map(\.text), segments.map(\.text))
        XCTAssertEqual(TranscriptOutput.paragraphs(segments).count, 1, "Other transcripts still merge short sentences")
        XCTAssertEqual(TranscriptOutput.labeledText(Array(segments.prefix(2)), eachSentence: true),
                       "You: Oggi parliamo di integrali.\n\nPartiamo dalla definizione!")
    }

    func testRollingAudioKeepsRecordingTimeAfterDiscarding() throws {
        var audio = RollingAudio()
        audio.append([Float](repeating: 0, count: 16_000))
        audio.append([Float](repeating: 0.1, count: 16_000))
        XCTAssertEqual(audio.end, 2)
        XCTAssertFalse(try XCTUnwrap(audio.audio(0..<1)).hasSpeech)
        let speech = try XCTUnwrap(audio.audio(0.5..<1.5))
        XCTAssertTrue(speech.hasSpeech)
        XCTAssertEqual(speech.start, 0.5)
        XCTAssertEqual(speech.samples.count, 16_000)
        audio.discard(before: 1.25)
        XCTAssertEqual(audio.start, 1.25)
        let rest = try XCTUnwrap(audio.audio(0..<5))
        XCTAssertEqual(rest.start, 1.25)
        XCTAssertEqual(rest.samples.count, 12_000)
        audio.discard(before: 0.5)
        XCTAssertEqual(audio.start, 1.25, "Discarding never moves backwards")
        audio.discard(before: 9)
        XCTAssertNil(audio.audio(0..<9))
        XCTAssertEqual(audio.end, 2)
    }

    func testTakeSettledHandsOutEachWordOnceAndKeepsTheBoundary() {
        var live = LiveText()
        let first = [word(1, " uno"), word(2, " due"), word(3, " tre"), word(4, " quattro"), word(12, " cinque")]
        live.accept(first, window: 0..<14)
        XCTAssertEqual(LiveText.join(live.takeSettled()), "uno due tre quattro")
        XCTAssertEqual(live.takeSettled().count, 0)
        XCTAssertEqual(LiveText.join(live.pending), "cinque")
        // The next request hears the last settled words again, a frame later.
        live.accept([word(3.02, " tre"), word(4.02, " quattro"), word(12, " cinque"), word(13, " sei")], window: 0..<20)
        XCTAssertEqual(LiveText.join(live.takeSettled()), "cinque sei")
        live.accept([word(13, " sei"), word(16, " sette")], window: 6..<17, final: true)
        XCTAssertEqual(LiveText.join(live.takeSettled()), "sette")
        XCTAssertTrue(live.pending.isEmpty)
        XCTAssertEqual(live.settledUntil, 17)
    }

    func testLegacyFallbackForUnsupportedLanguages() throws {
        let parakeet = try XCTUnwrap(TranscriptionModel.catalog.first { $0.id == "parakeet-v3" })
        XCTAssertEqual(TranscriptionModel.resolved(parakeet, language: "it", installed: ["turbo"]).id, "parakeet-v3")
        XCTAssertEqual(TranscriptionModel.resolved(parakeet, language: "ja", installed: []).id, "parakeet-v3")
        XCTAssertEqual(TranscriptionModel.resolved(parakeet, language: "ja", installed: ["tiny", "medium"]).id, "medium")
        XCTAssertEqual(TranscriptionModel.resolved(parakeet, language: "ja", installed: ["tiny", "turbo"]).id, "turbo")
        let small = try XCTUnwrap(TranscriptionModel.catalog.first { $0.id == "small" })
        XCTAssertEqual(TranscriptionModel.resolved(small, language: "ja", installed: ["turbo"]).id, "small")
    }

    func testLectureChunkerContinuesAfterAPauseFlush() throws {
        var chunker = Chunker.lecture
        let tone = (0..<(16_000 * 20)).map { Float(sin(Double($0) * 0.05) * 0.1) }
        XCTAssertTrue(chunker.append(tone).isEmpty)
        let first = try XCTUnwrap(chunker.flush())
        XCTAssertEqual(first.start, 0, accuracy: 0.6)
        XCTAssertTrue(chunker.append(tone).isEmpty)
        let second = try XCTUnwrap(chunker.flush())
        XCTAssertEqual(second.start, 20, accuracy: 0.6, "Recording time continues after the pause")
        XCTAssertEqual(second.duration, 20, accuracy: 0.6)
    }
}
