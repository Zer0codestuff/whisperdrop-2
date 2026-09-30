import XCTest
@testable import WhisperDropCore

final class SilenceGuardTests: XCTestCase {
    func testInventedItalianClosingsInSilentGapsAreRemoved() {
        let lines = [
            TranscriptSegment(id: 0, start: 1, end: 4, text: "La variabile è continua."),
            TranscriptSegment(id: 1, start: 6, end: 8, text: "Grazie. Grazie."),
            TranscriptSegment(id: 2, start: 10, end: 13, text: "Il valore è discreto."),
            TranscriptSegment(id: 3, start: 18, end: 20, text: "Ciao."),
        ]
        let result = SilenceGuard.filter(lines, speech: [SpeechRange(start: 0.9, end: 4.2), SpeechRange(start: 9.9, end: 13.2)])
        XCTAssertEqual(result.map(\.id), [0, 2])
    }

    func testRealQuietThanksAndGreetingsSurviveWithSpeechEvidence() {
        for phrase in ["Grazie.", "Grazie mille!", "Ciao.", "Thank you.", "Arrivederci."] {
            let lines = [TranscriptSegment(id: 0, start: 2, end: 4, text: phrase)]
            XCTAssertEqual(SilenceGuard.filter(lines, speech: [SpeechRange(start: 2.4, end: 2.8)]).map(\.text), [phrase])
            XCTAssertEqual(HallucinationFilter.clean(lines, preserveShortClosings: true).map(\.text), [phrase])
        }
    }

    func testOrdinarySentencesAndUnknownTimingAreNeverDeletedForWeakVAD() {
        let lines = [TranscriptSegment(id: 0, start: 0, end: 0, text: "Grazie."),
                     TranscriptSegment(id: 1, start: 2, end: 8, text: "Grazie per la domanda, ora torniamo al problema."),
                     TranscriptSegment(id: 2, start: 10, end: 20, text: "Questo passaggio ha una voce molto bassa.")]
        XCTAssertEqual(SilenceGuard.filter(lines, speech: []).map(\.text), lines.map(\.text))
    }

    func testUnsupportedClosingAfterPauseIsRemovedFromSentenceWithWordTimes() {
        let words = [TranscriptWord(start: 1, end: 2, text: " La variabile"), TranscriptWord(start: 2, end: 3, text: " è continua."),
                     TranscriptWord(start: 6, end: 8, text: " Grazie.")]
        let line = TranscriptSegment(id: 0, start: 1, end: 8, text: "La variabile è continua. Grazie.", words: words)
        let filtered = SilenceGuard.filter([line], speech: [SpeechRange(start: 1, end: 3.1)])
        XCTAssertEqual(filtered.first?.text, "La variabile è continua.")
        XCTAssertEqual(filtered.first?.end, 3)
        XCTAssertEqual(filtered.first?.words?.count, 2)
    }
}
