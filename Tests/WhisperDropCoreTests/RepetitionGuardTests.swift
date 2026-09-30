import XCTest
@testable import WhisperDropCore

final class RepetitionGuardTests: XCTestCase {
    func testSustainedDecoderLoopRequestsRecoveryWithoutRemovingText() {
        let loop = String(repeating: "Per esempio, in operazione di rispetto. ", count: 15)
        XCTAssertGreaterThan(RepetitionGuard.score(loop), 0.3)
        XCTAssertTrue(RepetitionGuard.prefers("Possiamo confrontare i valori sulla scala di intervallo.", over: loop))
        XCTAssertFalse(RepetitionGuard.prefers("", over: loop))
        XCTAssertFalse(RepetitionGuard.prefers(loop, over: loop))
    }

    func testNormalRepeatedSentencesAndCommonLectureTermsDoNotTriggerRecovery() {
        let repeated = String(repeating: "Questa variabile indica il valore della funzione obiettivo. ", count: 3)
        XCTAssertEqual(RepetitionGuard.score(repeated), 0)
        XCTAssertEqual(RepetitionGuard.score("Grazie. Grazie. Grazie."), 0)
        XCTAssertFalse(RepetitionGuard.prefers("A different sentence with enough words.", over: repeated))
    }

    func testDictationLoopsNeedBackToBackRepeats() {
        let loop = "Then you can make a guide, you can make a guide, you can make a guide, you can make a guide, because it is better."
        XCTAssertEqual(RepetitionGuard.loopedWords(loop), 15)
        XCTAssertTrue(RepetitionGuard.dictationLoops(loop))
        XCTAssertFalse(RepetitionGuard.dictationLoops("No, no, no. Grazie. Grazie. Grazie."))
        XCTAssertFalse(RepetitionGuard.dictationLoops("Molto molto bene, ci vediamo domani, ci vediamo presto."))
        XCTAssertTrue(RepetitionGuard.dictationLoops("the the the the the end"))
        XCTAssertFalse(RepetitionGuard.dictationLoops(""))
    }

    func testDictationRetryMustRepeatLessAndKeepTheRest() {
        let loop = "Then you can make a guide, you can make a guide, you can make a guide, you can make a guide, because it is better."
        XCTAssertTrue(RepetitionGuard.dictationPrefers("Then you can make a guide, because it is better.", over: loop))
        XCTAssertFalse(RepetitionGuard.dictationPrefers("Then you.", over: loop))
        XCTAssertFalse(RepetitionGuard.dictationPrefers(loop, over: loop))
        XCTAssertFalse(RepetitionGuard.dictationPrefers("A different sentence.", over: "A normal sentence."))
    }
}
