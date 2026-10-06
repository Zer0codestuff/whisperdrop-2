import XCTest
@testable import WhisperDropCore

final class UpdatePolicyTests: XCTestCase {
    func testEveryActiveOperationBlocksRestart() {
        XCTAssertNil(UpdateActivity().blockingReason)
        let properties: [WritableKeyPath<UpdateActivity, Bool>] = [\.recording, \.dictating, \.transcribing, \.importing,
            \.movingFiles, \.downloadingModel, \.editing, \.replacingText, \.reviewingSelection]
        for property in properties {
            var activity = UpdateActivity(); activity[keyPath: property] = true
            XCTAssertNotNil(activity.blockingReason)
        }
    }
    func testProductionFeedsRequireHTTPSAndAValidPublicKey() throws {
        let key = Data(repeating: 1, count: 32).base64EncodedString()
        _ = try UpdateConfiguration(feed: "https://example.com/appcast.xml", publicKey: key)
        for feed in ["http://example.com/feed", "http://127.0.0.1/feed", "file:///tmp/feed", "https://user:password@example.com/feed", "https://example.com/feed#fragment"] {
            XCTAssertThrowsError(try UpdateConfiguration(feed: feed, publicKey: key))
        }
        XCTAssertThrowsError(try UpdateConfiguration(feed: "https://example.com/feed", publicKey: "invalid"))
        _ = try UpdateConfiguration(feed: "http://127.0.0.1:8000/feed", publicKey: key, verification: true)
        XCTAssertThrowsError(try UpdateConfiguration(feed: "http://example.com/feed", publicKey: key, verification: true))
    }
}
