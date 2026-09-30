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
}
