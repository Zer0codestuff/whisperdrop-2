import XCTest
@testable import WhisperDropCore

final class ProcessingTests: XCTestCase {
    func testSpeechBurstsCutAtSilencesWithAbsoluteStarts() {
        // 0-2 s quiet, 2-4 s tone, 4-10 s quiet, 10-12 s tone, 12-15 s quiet.
        // A 3 s open pause closes the chunk; leading quiet is kept only as 0.30 s of pre-roll.
        let timeline = silence(2) + tone(2) + silence(6) + tone(2) + silence(3)
        var chunker = Chunker(target: 20, maxLength: 30, minLength: 1)
        let chunks = feed(&chunker, timeline, sliceSamples: 1_600)

        XCTAssertEqual(chunks.count, 2, "starts \(chunks.map(\.start)) counts \(chunks.map(\.samples.count))")
        XCTAssertEqual(chunks[0].samples.count, 38_080)
        XCTAssertEqual(chunks[0].start, 1.7, accuracy: 1e-6)
        XCTAssertTrue(chunks[0].hasSpeech)
        XCTAssertEqual(chunks[1].samples.count, 38_080)
        XCTAssertEqual(chunks[1].start, 9.7, accuracy: 1e-6)
        XCTAssertTrue(chunks[1].hasSpeech)
        XCTAssertGreaterThanOrEqual(chunks[1].start, chunks[0].start + chunks[0].duration - 1e-6)
        XCTAssertLessThanOrEqual(chunks[0].duration, 30)
        XCTAssertLessThanOrEqual(chunks[1].duration, 30)
    }

    func testLongestPauseInTheBandWins() {
        // Pauses at 16.0 s (0.5 s) and 22.0 s (0.9 s). Lookahead waits until 25 s, then cuts the longer one.
        let timeline = tone(16) + silence(0.5) + tone(5.5) + silence(0.9) + tone(3.1)
        var chunker = Chunker(target: 20, maxLength: 30, minLength: 1)
        let chunks = chunker.append(timeline)
        XCTAssertEqual(chunks.count, 1, "starts \(chunks.map(\.start)) counts \(chunks.map(\.samples.count))")
        XCTAssertEqual(chunks[0].start, 0, accuracy: 1e-9)
        XCTAssertEqual(chunks[0].samples.count, 353_280)
        XCTAssertTrue(chunks[0].hasSpeech)
    }

    func testPauseBeforeTheBandDoesNotCutEarly() {
        var timeline = tone(30)
        let gapStart = 10 * whisperSampleRate
        let gapEnd = gapStart + 9_600
        for index in gapStart..<gapEnd { timeline[index] = 0 }
        var chunker = Chunker(target: 20, maxLength: 30, minLength: 1)
        let chunks = chunker.append(timeline)
        XCTAssertEqual(chunks.count, 1, "starts \(chunks.map(\.start)) counts \(chunks.map(\.samples.count))")
        XCTAssertEqual(chunks[0].samples.count, 30 * whisperSampleRate)
        XCTAssertEqual(chunks[0].start, 0, accuracy: 1e-9)
    }

    func testContinuousToneCutsAtMaxLengthAndFlushReturnsTail() throws {
        var chunker = Chunker()
        var chunks: [AudioChunk] = []
        let samples = tone(32)
        var offset = 0
        while offset < samples.count {
            let end = min(offset + 320, samples.count)
            chunks.append(contentsOf: chunker.append(Array(samples[offset..<end])))
            offset = end
        }
        XCTAssertEqual(chunks.count, 1)
        XCTAssertEqual(chunks[0].samples.count, 28 * whisperSampleRate)
        XCTAssertEqual(chunks[0].start, 0, accuracy: 1e-9)
        XCTAssertTrue(chunks[0].hasSpeech)
        let tail = try XCTUnwrap(chunker.flush())
        XCTAssertEqual(tail.samples.count, 4 * whisperSampleRate)
        XCTAssertEqual(tail.start, 28, accuracy: 1e-6)
        XCTAssertTrue(tail.hasSpeech)
        XCTAssertLessThanOrEqual(tail.duration, chunker.maxLength)
    }

    func testPureSilenceYieldsHasSpeechFalse() {
        let quiet = [Float](repeating: 0, count: whisperSampleRate * 60)
        let hum = [Float](repeating: 0.005, count: whisperSampleRate)
        XCTAssertFalse(SpeechDetector.hasSpeech(quiet))
        XCTAssertFalse(SpeechDetector.hasSpeech(hum))
        XCTAssertFalse(SpeechDetector.hasSpeech([]))
        XCTAssertTrue(SpeechDetector.hasSpeech(tone(0.5)))
        XCTAssertEqual(SpeechDetector.rms([][...]), 0)
        XCTAssertEqual(SpeechDetector.rms(ArraySlice([Float](repeating: 0.5, count: 320))), 0.5, accuracy: 1e-5)

        var chunker = Chunker(target: 20, maxLength: 30, minLength: 1)
        let chunks = feed(&chunker, quiet, sliceSamples: 320)
        XCTAssertTrue(chunks.isEmpty)
        XCTAssertNil(chunker.flush())
    }

    func testTrimSilenceKeepsPaddingAndDropsPureSilence() {
        let samples = silence(1) + tone(0.5) + silence(1)
        let trimmed = SpeechDetector.trimSilence(samples, padding: 0.2)
        XCTAssertEqual(trimmed.count, 8_000 + 3_200 + 3_200)
        XCTAssertGreaterThan(SpeechDetector.rms(ArraySlice(trimmed)), 0.015)
        XCTAssertEqual(SpeechDetector.trimSilence(silence(1)), [])
        XCTAssertEqual(SpeechDetector.trimSilence(silence(0.2) + tone(0.5), padding: 0.2).count, 3_200 + 8_000)
    }

    func testHallucinationFilterDropsPhrasesAndKeepsSentences() {
        let segments = [
            segment("Thank you."),
            segment("Thanks for watching!"),
            segment("Grazie per la visione."),
            segment("[Music]"),
            segment("(applause)"),
            segment("[BLANK_AUDIO]"),
            segment("yes yes yes yes yes yes"),
            segment("The room went quiet [Music] and then she spoke."),
            segment("Welcome (applause) to the meeting."),
            segment("Thank you for the update on the budget."),
            segment("Dobbiamo inviare il contratto entro venerdì."),
            segment("We will ship the update on Friday."),
            segment("We will ship the update on Friday."),
            segment("ご視聴ありがとうございました"),
            segment("Merci d'avoir regardé."),
        ]
        XCTAssertEqual(HallucinationFilter.clean(segments).map(\.text), [
            "The room went quiet and then she spoke.",
            "Welcome to the meeting.",
            "Thank you for the update on the budget.",
            "Dobbiamo inviare il contratto entro venerdì.",
            "We will ship the update on Friday.",
        ])
    }

    func testDictationTextDropsLoneThankYouFromSilentAudio() {
        // Whisper prints "Thank you." on quiet audio (openai/whisper discussion 679).
        // There is no energy field on ServerTranscription, so that only-input is the silent-like case.
        let silent = ServerTranscription(
            segments: [segment(" Thank you. ")],
            language: "english"
        )
        XCTAssertNil(HallucinationFilter.dictationText(silent))

        let said = ServerTranscription(segments: [
            segment("  Send the file. "),
            segment("Thank you."),
            segment("I need it today."),
        ], language: "english")
        XCTAssertEqual(HallucinationFilter.dictationText(said), "Send the file. I need it today.")
        XCTAssertNil(HallucinationFilter.dictationText(ServerTranscription(segments: [], language: nil)))
    }

    func testMergeOrdersByStartDropsEchoAndRenumbers() {
        let you = [
            segment("Good morning everyone.", start: 0, end: 1.2, speaker: .you, id: 9),
            segment("yes", start: 2, end: 2.4, speaker: .you, id: 10),
            segment("I will send the notes after this call today.", start: 3, end: 5, speaker: .you, id: 11),
            segment("please send the quarterly report before friday", start: 8, end: 10, speaker: .you, id: 12),
        ]
        let others = [
            segment("Good morning everyone.", start: 0.2, end: 1.4, speaker: .others, id: 3),
            segment("yes", start: 2, end: 2.5, speaker: .others, id: 4),
            segment("The archive policy changed last month.", start: 3, end: 4, speaker: .others, id: 1),
            segment("yes please send the quarterly report before friday if you can", start: 8.2, end: 11, speaker: .others, id: 5),
        ]
        let merged = TranscriptMerger.merge(you: you, others: others)
        XCTAssertEqual(merged.map(\.text), [
            "Good morning everyone.",
            "yes",
            "yes",
            "The archive policy changed last month.",
            "I will send the notes after this call today.",
            "yes please send the quarterly report before friday if you can",
        ])
        XCTAssertEqual(merged.map(\.speaker), [.others, .others, .you, .others, .you, .others])
        XCTAssertEqual(merged.map(\.id), [0, 1, 2, 3, 4, 5])
        XCTAssertEqual(TranscriptMerger.similarity("Hello!", "hello"), 1, accuracy: 1e-9)
        XCTAssertEqual(TranscriptMerger.similarity("abcdef", "abcxyz"), 0.5, accuracy: 1e-9)
        XCTAssertEqual(TranscriptMerger.similarity("", ""), 1, accuracy: 1e-9)
    }

    func testLabeledTextGroupsSpeakersOrPrintsLines() {
        let plain = [
            segment("First line."),
            segment("Second line."),
        ]
        XCTAssertEqual(TranscriptOutput.labeledText(plain), "First line.\nSecond line.")

        let spoken = [
            segment("Hello.", speaker: .you),
            segment("How are you?", speaker: .you),
            segment("I am fine.", speaker: .others),
            segment("Good.", speaker: .others),
            segment("Back to me.", speaker: .you),
        ]
        XCTAssertEqual(
            TranscriptOutput.labeledText(spoken),
            "You: Hello. How are you?\n\nOthers: I am fine. Good.\n\nYou: Back to me."
        )
    }

    private func tone(_ seconds: Double, amplitude: Float = 0.5) -> [Float] {
        let count = Int((seconds * Double(whisperSampleRate)).rounded(.toNearestOrAwayFromZero))
        guard count > 0 else { return [] }
        var samples = [Float](repeating: 0, count: count)
        let step = 2 * Double.pi * 440 / Double(whisperSampleRate)
        for index in 0..<count {
            samples[index] = amplitude * Float(sin(Double(index) * step))
        }
        return samples
    }

    private func silence(_ seconds: Double) -> [Float] {
        let count = Int((seconds * Double(whisperSampleRate)).rounded(.toNearestOrAwayFromZero))
        return [Float](repeating: 0, count: max(0, count))
    }

    private func feed(_ chunker: inout Chunker, _ samples: [Float], sliceSamples: Int) -> [AudioChunk] {
        var emitted: [AudioChunk] = []
        var offset = 0
        while offset < samples.count {
            let end = min(offset + sliceSamples, samples.count)
            emitted.append(contentsOf: chunker.append(Array(samples[offset..<end])))
            offset = end
        }
        return emitted
    }

    private func segment(
        _ text: String,
        start: Double = 0,
        end: Double = 1,
        speaker: Speaker? = nil,
        id: Int = 0
    ) -> TranscriptSegment {
        TranscriptSegment(id: id, start: start, end: end, text: text, speaker: speaker)
    }
}
