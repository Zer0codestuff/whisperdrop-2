import XCTest
@testable import WhisperDrop

@MainActor
final class AppSettingsTests: XCTestCase {
    func testDefaultsPreferTurboAndTenMinuteResidency() {
        let settings = AppSettings(defaults: UserDefaults(suiteName: "WhisperDropAppTests.\(UUID().uuidString)")!)
        XCTAssertEqual(settings.model.id, "turbo")
        XCTAssertEqual(settings.residency, .tenMinutes)
        XCTAssertEqual(settings.hotkey, .fn)
    }

    func testSpokenLanguageKeepsTheFirstExplicitLegacyChoice() {
        let defaults = UserDefaults(suiteName: "WhisperDropAppTests.\(UUID().uuidString)")!
        defaults.set("it", forKey: "language")
        defaults.set("en", forKey: "noteLanguage")
        XCTAssertEqual(AppSettings(defaults: defaults).spokenLanguage, "it")
        XCTAssertEqual(defaults.string(forKey: "spokenLanguage"), "it")
        defaults.set("fr", forKey: "language")
        XCTAssertEqual(AppSettings(defaults: defaults).spokenLanguage, "it")
    }

    func testSpokenLanguageSkipsAutoAndFallsBackToTheMacLanguage() {
        let defaults = UserDefaults(suiteName: "WhisperDropAppTests.\(UUID().uuidString)")!
        defaults.set("auto", forKey: "language")
        defaults.set("auto", forKey: "dictationLanguage")
        XCTAssertEqual(AppSettings.initialLanguage(defaults, preferred: ["it-IT", "en-US"]), "it")
        XCTAssertEqual(AppSettings.initialLanguage(defaults, preferred: ["is-IS"]), "auto")
        defaults.set("de", forKey: "dictationLanguage")
        XCTAssertEqual(AppSettings.initialLanguage(defaults, preferred: ["it-IT"]), "de")
    }

    func testNextNoteLanguageOverridesOnce() {
        let settings = AppSettings(defaults: UserDefaults(suiteName: "WhisperDropAppTests.\(UUID().uuidString)")!)
        settings.spokenLanguage = "it"
        XCTAssertEqual(settings.noteLanguage, "it")
        settings.nextNoteLanguage = "en"
        XCTAssertEqual(settings.noteLanguage, "en")
    }

    func testStartingANoteFreezesAndClearsTheOneTimeLanguage() async {
        let defaults = UserDefaults(suiteName: "WhisperDropAppTests.\(UUID().uuidString)")!
        defaults.set(true, forKey: "noteLanguageReminderSeen")
        let settings = AppSettings(defaults: defaults)
        settings.spokenLanguage = "it"
        settings.nextNoteLanguage = "en"
        let host = ModelHost(tool: { _ in throw AppFailure("No tools in tests.") }, modelFile: { _ in throw AppFailure("No models in tests.") })
        let factory = NoteCaptureFactory(makeMicrophone: { MicCapture() }, makeSystemTap: { SystemAudioTap() }, makeWriter: { try AudioFileWriter(url: $0) },
                                         requestMicrophoneAccess: { false }, systemAudioSupported: { false })
        let recorder = NoteRecorder(settings: settings, host: host, folder: FileManager.default.temporaryDirectory, onFinish: { _ in },
                                    captures: factory, defaults: defaults)
        recorder.requestStart(.microphone)
        XCTAssertEqual(recorder.sessionLanguage, "en")
        XCTAssertNil(settings.nextNoteLanguage)
        XCTAssertEqual(settings.noteLanguage, "it")
        for _ in 0..<100 where !Self.failed(recorder.state) { try? await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(Self.failed(recorder.state))
    }

    private static func failed(_ state: NoteRecorder.State) -> Bool { if case .failed = state { true } else { false } }
}
