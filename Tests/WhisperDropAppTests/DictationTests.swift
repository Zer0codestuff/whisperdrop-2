import XCTest
@testable import WhisperDrop

final class DictationTests: XCTestCase {
    func testHoldReleaseTranscribes() {
        for mode in [DictationMode.hold, .holdOrDoubleTap] {
            var gesture = DictationGesture(mode: mode, doubleTapInterval: 0.5)
            XCTAssertEqual(gesture.holdThreshold, 0.2)
            XCTAssertEqual(gesture.press(at: 2), [.start(handsFree: false)])
            XCTAssertEqual(gesture.release(at: 2.2), [.commit])
        }
        var boundary = DictationGesture(mode: .hold, doubleTapInterval: 0.5)
        XCTAssertEqual(boundary.press(at: 0), [.start(handsFree: false)])
        XCTAssertEqual(boundary.release(at: 0.2), [.commit])
    }

    func testShortTapDiscards() {
        var gesture = DictationGesture(mode: .holdOrDoubleTap, doubleTapInterval: 0.5)
        XCTAssertEqual(gesture.press(at: 0), [.start(handsFree: false)])
        XCTAssertEqual(gesture.release(at: 0.19), [])
        XCTAssertEqual(gesture.pendingDiscardAt, 0.5)
        XCTAssertEqual(gesture.timeout(at: 0.49), [])
        XCTAssertEqual(gesture.timeout(at: 0.5), [.discard])
        XCTAssertNil(gesture.pendingDiscardAt)

        var hold = DictationGesture(mode: .hold, doubleTapInterval: 0.5)
        XCTAssertEqual(hold.press(at: 0), [.start(handsFree: false)])
        XCTAssertEqual(hold.release(at: 0.05), [.discard])
        XCTAssertEqual(hold.press(at: 0.2), [.start(handsFree: false)])
        XCTAssertEqual(hold.release(at: 0.25), [.discard])

        var late = DictationGesture(mode: .holdOrDoubleTap, doubleTapInterval: 0.5)
        XCTAssertEqual(late.press(at: 0), [.start(handsFree: false)])
        XCTAssertEqual(late.release(at: 0.1), [])
        XCTAssertEqual(late.press(at: 0.51), [.discard, .start(handsFree: false)])
        XCTAssertEqual(late.release(at: 0.8), [.commit])
    }

    func testDoubleTapHandsFreeThenStop() {
        var gesture = DictationGesture(mode: .holdOrDoubleTap, doubleTapInterval: 0.5)
        XCTAssertEqual(gesture.press(at: 1), [.start(handsFree: false)])
        XCTAssertEqual(gesture.release(at: 1.05), [])
        XCTAssertEqual(gesture.press(at: 1.5), [])
        XCTAssertEqual(gesture.release(at: 1.55), [.becomeHandsFree])
        XCTAssertNil(gesture.pendingDiscardAt)
        XCTAssertEqual(gesture.press(at: 4), [.commit])
        XCTAssertEqual(gesture.release(at: 4.05), [])
        XCTAssertEqual(gesture.press(at: 5), [.start(handsFree: false)])
    }

    func testLongSecondPressCommitsInsteadOfHandsFree() {
        var gesture = DictationGesture(mode: .holdOrDoubleTap, doubleTapInterval: 0.5)
        XCTAssertEqual(gesture.press(at: 0), [.start(handsFree: false)])
        XCTAssertEqual(gesture.release(at: 0.05), [])
        XCTAssertEqual(gesture.press(at: 0.3), [])
        XCTAssertEqual(gesture.release(at: 0.6), [.commit])
    }

    func testToggleMode() {
        var gesture = DictationGesture(mode: .toggle, doubleTapInterval: 0.5)
        XCTAssertEqual(gesture.press(at: 0), [.start(handsFree: true)])
        XCTAssertEqual(gesture.release(at: 0.8), [])
        XCTAssertEqual(gesture.press(at: 2), [.commit])
        XCTAssertEqual(gesture.release(at: 2.1), [])
        XCTAssertEqual(gesture.press(at: 3), [.start(handsFree: true)])
    }

    func testCancelWhileHoldingDiscards() {
        var gesture = DictationGesture(mode: .holdOrDoubleTap, doubleTapInterval: 0.5)
        XCTAssertEqual(gesture.press(at: 0), [.start(handsFree: false)])
        XCTAssertEqual(gesture.cancel(at: 0.1), [.discard])
        XCTAssertEqual(gesture.release(at: 0.4), [])
        XCTAssertEqual(gesture.press(at: 1), [.start(handsFree: false)])

        var toggle = DictationGesture(mode: .toggle, doubleTapInterval: 0.5)
        XCTAssertEqual(toggle.press(at: 0), [.start(handsFree: true)])
        XCTAssertEqual(toggle.cancel(at: 0.2), [.discard])
        XCTAssertEqual(toggle.release(at: 0.3), [])
        XCTAssertEqual(toggle.press(at: 1), [.start(handsFree: true)])
    }
}
