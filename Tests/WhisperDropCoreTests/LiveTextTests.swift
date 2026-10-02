import XCTest
@testable import WhisperDropCore

final class LiveTextTests: XCTestCase {
    /// Short settings keep the fixtures small. The production defaults are checked separately.
    private func LiveText(start: Double = 0) -> WhisperDropCore.LiveText {
        var live = WhisperDropCore.LiveText(start: start)
        live.leftContext = 3
        live.settleAfter = 4
        live.maxWindow = 24
        return live
    }

    func testDefaultsGiveTenSecondsOfContext() {
        let live = WhisperDropCore.LiveText()
        XCTAssertEqual(live.leftContext, 10)
        XCTAssertEqual(live.settleAfter, 6)
        XCTAssertEqual(live.maxWindow, 30)
    }

    /// One word per second from `from`, named w0, w1, ...
    private func words(_ range: Range<Int>, prefix: String = "w") -> [TranscriptWord] {
        range.map { TranscriptWord(start: Double($0) + 0.1, end: Double($0) + 0.8, text: " \(prefix)\($0)") }
    }

    func testWordsSettleOnceAudioFollowsThem() {
        var live = LiveText()
        let first = live.window(audioStart: 0, end: 6)!
        XCTAssertEqual(first, 0..<6)
        live.accept(words(0..<6), window: first)
        XCTAssertEqual(live.settledText, "w0 w1", "Words ending at least four seconds before the window end settle")
        XCTAssertEqual(live.text, "w0 w1 w2 w3 w4 w5")
        XCTAssertEqual(live.settledUntil, 1.95, accuracy: 0.001, "The boundary sits in the gap after the last settled word")
    }

    func testTheTextKeepsEverythingWhileWindowsStayShort() {
        var live = LiveText()
        var end = 0.0
        while end < 90 {
            end += 0.8
            guard let window = live.window(audioStart: 0, end: end) else { continue }
            XCTAssertLessThanOrEqual(window.upperBound - window.lowerBound, live.maxWindow + 0.001)
            let heard = words(Int(window.lowerBound.rounded(.down))..<Int(window.upperBound.rounded(.down)))
                .filter { $0.end <= window.upperBound && $0.start >= window.lowerBound }
            live.accept(heard, window: window)
        }
        let expected = (0..<89).map { "w\($0)" }.joined(separator: " ")
        XCTAssertTrue(live.text.hasPrefix(expected.split(separator: " ").prefix(80).joined(separator: " ")), live.text)
        XCTAssertGreaterThan(live.settled.count, 80, "A 90 second dictation keeps its early words")
        XCTAssertEqual(Set(live.settled.map(\.text)).count, live.settled.count, "Overlapping windows never repeat a word")
    }

    func testRedecodedContextIsNotRepeated() {
        var live = LiveText()
        live.accept(words(0..<10), window: 0..<10)
        let settled = live.settledText
        let next = live.window(audioStart: 0, end: 12)!
        XCTAssertEqual(next.lowerBound, live.settledUntil - live.leftContext, accuracy: 0.001)
        // The new request hears the context again, possibly with different casing.
        let again = words(Int(next.lowerBound.rounded(.down))..<12, prefix: "w").map { word -> TranscriptWord in
            var word = word
            if word.start < live.settledUntil { word.text = word.text.uppercased() }
            return word
        }
        live.accept(again, window: next)
        XCTAssertTrue(live.text.hasPrefix(settled))
        XCTAssertFalse(live.text.contains("W"), "Words before the boundary come from the earlier request")
    }

    func testAWordHeardAgainWithShiftedTimesIsNotRepeated() {
        var live = LiveText()
        let first = [TranscriptWord(start: 9.0, end: 9.3, text: " ripigliò"), TranscriptWord(start: 9.36, end: 9.52, text: " la"),
                     TranscriptWord(start: 9.6, end: 10.0, text: " donna")]
        live.accept(first, window: 5..<13.6)
        XCTAssertEqual(live.settledText, "ripigliò la")
        XCTAssertEqual(live.settledUntil, 9.56, accuracy: 0.001)
        // The next request places "la" one frame later and "donna" a little earlier.
        let again = [TranscriptWord(start: 9.44, end: 9.6, text: " la"), TranscriptWord(start: 9.54, end: 9.9, text: " donna"),
                     TranscriptWord(start: 10.0, end: 10.3, text: " spiriti")]
        live.accept(again, window: 6.56..<16)
        XCTAssertEqual(live.text, "ripigliò la donna spiriti")
    }

    func testARealRepetitionLaterInTimeIsKept() {
        var live = LiveText()
        live.accept([TranscriptWord(start: 1.0, end: 1.2, text: " al"), TranscriptWord(start: 1.3, end: 1.9, text: " manicomio")], window: 0..<6)
        live.accept([TranscriptWord(start: 1.3, end: 1.9, text: " manicomio"), TranscriptWord(start: 2.2, end: 2.4, text: " al"),
                     TranscriptWord(start: 2.5, end: 3.1, text: " manicomio")], window: 0..<8, final: true)
        XCTAssertEqual(live.text, "al manicomio al manicomio")
    }

    func testSilenceMovesTheBoundary() {
        var live = LiveText()
        live.accept([], window: 0..<20)
        XCTAssertEqual(live.settledUntil, 16)
        XCTAssertEqual(live.window(audioStart: 0, end: 25)!.lowerBound, 13)
    }

    func testFinalPassSettlesEverything() {
        var live = LiveText()
        live.accept(words(0..<8), window: 0..<8)
        let window = (live.settledUntil - live.leftContext)..<9.5
        live.accept(words(1..<9), window: window, final: true)
        XCTAssertEqual(live.settledText, (0..<9).map { "w\($0)" }.joined(separator: " "))
        XCTAssertTrue(live.pending.isEmpty)
    }

    func testCommittedChunksRemoveTheirWords() {
        var live = LiveText()
        live.accept(words(0..<12), window: 0..<12)
        live.discard(through: 5)
        XCTAssertEqual(live.text.split(separator: " ").first, "w5")
        XCTAssertGreaterThanOrEqual(live.settledUntil, 5)
    }

    func testEditsDeleteOnlyTheChangedEnd() {
        XCTAssertEqual(LiveTextEdit.between("Ciao come", "Ciao come stai"), .replace(delete: 0, insert: " stai"))
        XCTAssertEqual(LiveTextEdit.between("Ciao Torchemada", "Ciao Torquemada"), .replace(delete: 7, insert: "quemada"))
        XCTAssertEqual(LiveTextEdit.between("perché è", "perché"), .replace(delete: 2, insert: ""))
        XCTAssertEqual(LiveTextEdit.between("", "Sì"), .replace(delete: 0, insert: "Sì"))
    }

    func testChunkerOpenAudioUsesRecordingTime() {
        var chunker = Chunker.lecture
        let tone = (0..<16_000 * 10).map { Float(sin(Double($0) * 0.05) * 0.2) }
        XCTAssertTrue(chunker.append(tone).isEmpty)
        XCTAssertEqual(chunker.openStart, 0)
        XCTAssertEqual(chunker.openEnd, 10, accuracy: 0.0001)
        let audio = chunker.openAudio(2..<5)!
        XCTAssertEqual(audio.start, 2, accuracy: 0.0001)
        XCTAssertEqual(audio.samples.count, 48_000)
        XCTAssertTrue(audio.hasSpeech)
        XCTAssertEqual(chunker.openAudio(8..<30)!.samples.count, 32_000, "Clamped to the audio that exists")
        XCTAssertNil(chunker.openAudio(12..<20))
    }
}
