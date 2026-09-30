import XCTest
@testable import WhisperDrop

@MainActor
final class SpeechActivityDetectorTests: XCTestCase {
    func testPinnedToolCentisecondsBecomeAbsoluteSeconds() throws {
        let result = try SpeechActivityDetector.parse("Detected 2 speech segments:\nSpeech segment 0: start = 120.00, end = 340.00\nSpeech segment 1: start = 500.00, end = 650.00\n", offset: 60)
        XCTAssertEqual(result.map(\.start), [61.2, 65])
        XCTAssertEqual(result.map(\.end), [63.4, 66.5])
        XCTAssertEqual(try SpeechActivityDetector.parse("Detected 0 speech segments:\n"), [])
        XCTAssertThrowsError(try SpeechActivityDetector.parse("an error"))
        XCTAssertThrowsError(try SpeechActivityDetector.parse("Detected 2 speech segments:\n"))
    }
}
