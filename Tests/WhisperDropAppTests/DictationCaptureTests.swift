import XCTest
@testable import WhisperDrop

@MainActor
final class DictationCaptureTests: XCTestCase {
    private final class Microphone: NoteCaptureSource {
        var onSamples: (@Sendable ([Float]) -> Void)?
        var onLevel: (@Sendable (Float) -> Void)?
        var droppedPacketCount = 0
        var failureMessage: String?
        var starts = 0
        var stops = 0
        func start() throws { starts += 1; failureMessage = nil; onSamples?(Array(repeating: 0, count: 1600)) }
        func stop() { stops += 1 }
    }

    func testMicrophoneFailureStopsDictationAndReportsIt() async throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "DictationCaptureTests.\(UUID().uuidString)"))
        let settings = AppSettings(defaults: defaults)
        settings.sounds = false
        settings.autoPaste = false
        settings.dictationLiveText = .off
        let host = ModelHost(tool: { _ in throw AppFailure("No test server") }, modelFile: { _ in URL(fileURLWithPath: "/missing") })
        let microphone = Microphone()
        let controller = DictationController(settings: settings, host: host, microphone: microphone,
                                              microphoneAuthorized: { true }, showHUD: false)
        defer { controller.cancel(); host.shutdown() }
        controller.toggle()
        for _ in 0..<100 where microphone.starts == 0 { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(microphone.starts, 1)
        microphone.failureMessage = "Input device unavailable"
        for _ in 0..<150 {
            if case .failed = controller.state { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(controller.state, .failed("The microphone stopped. Dictation may be incomplete."))
        XCTAssertGreaterThan(microphone.stops, 0)
    }
}
