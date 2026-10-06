import XCTest
import WhisperDropCore
@testable import WhisperDrop

@MainActor
final class AppSettingsTests: XCTestCase {
    func testDefaultsPreferParakeetAndTenMinuteResidency() {
        let settings = AppSettings(defaults: UserDefaults(suiteName: "WhisperDropAppTests.\(UUID().uuidString)")!)
        XCTAssertEqual(settings.model.id, "parakeet-v3")
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

    func testUnsupportedNoteLanguageDoesNotOpenCaptureOrLoadAModel() async throws {
        let suite = "WhisperDropAppTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: "noteLanguageReminderSeen")
        let settings = AppSettings(defaults: defaults)
        settings.mainModel = "parakeet-v3"
        settings.spokenLanguage = "it"
        settings.nextNoteLanguage = "ja"
        var requestedAccess = false
        var requestedModel = false
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("unsupported-note-\(UUID().uuidString)")
        let host = ModelHost(tool: { _ in throw AppFailure("No tools in tests.") }, modelFile: { _ in
            requestedModel = true
            throw AppFailure("No models in tests.")
        }, processFile: folder.appendingPathComponent("server.pid"))
        defer { host.shutdown() }
        let factory = NoteCaptureFactory(makeMicrophone: { MicCapture() }, makeSystemTap: { SystemAudioTap() },
                                         makeWriter: { try AudioFileWriter(url: $0) }, requestMicrophoneAccess: {
            requestedAccess = true
            return false
        }, systemAudioSupported: { false })
        let recorder = NoteRecorder(settings: settings, host: host, folder: folder, onFinish: { _ in XCTFail("No note should be saved") },
                                    captures: factory, defaults: defaults)
        recorder.requestStart(.microphone)
        await Task.yield()
        XCTAssertEqual(recorder.state, .failed("Parakeet v3 does not transcribe Japanese. Download a legacy Whisper model in Settings, Models."))
        XCTAssertFalse(requestedAccess)
        XCTAssertFalse(requestedModel)
        XCTAssertEqual(host.state, .unloaded)
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path))
        XCTAssertEqual(settings.nextNoteLanguage, "ja", "A refused start should retain the next-note language")
    }

    func testOneModelReplacesTheSeparateFileAndLiveChoices() {
        let defaults = UserDefaults(suiteName: "WhisperDropAppTests.\(UUID().uuidString)")!
        defaults.set("small", forKey: "model")
        defaults.set("parakeet-v3", forKey: "liveModel")
        let settings = AppSettings(defaults: defaults)
        XCTAssertEqual(settings.mainModel, "parakeet-v3", "The Settings choice wins over the old main window choice")
        for task in ModelTask.allCases {
            XCTAssertEqual(settings.model(for: task).id, "parakeet-v3")
            XCTAssertNil(settings.ownModel(for: task))
        }
        XCTAssertEqual(AppSettings(defaults: defaults).mainModel, "parakeet-v3")

        let fresh = UserDefaults(suiteName: "WhisperDropAppTests.\(UUID().uuidString)")!
        fresh.set("small", forKey: "model")
        XCTAssertEqual(AppSettings(defaults: fresh).mainModel, "small", "Without a live model the file model is kept")
        fresh.set("missing-model", forKey: "mainModel")
        XCTAssertEqual(AppSettings(defaults: fresh).mainModel, "small", "Unknown ids fall back")
    }

    func testATaskCanFollowOrLeaveTheMainModel() {
        let defaults = UserDefaults(suiteName: "WhisperDropAppTests.\(UUID().uuidString)")!
        let settings = AppSettings(defaults: defaults)
        settings.mainModel = "turbo"
        settings.setOwnModel("parakeet-v3", for: .dictation)
        XCTAssertEqual(settings.model(for: .dictation).id, "parakeet-v3")
        XCTAssertEqual(settings.model(for: .notes).id, "turbo")
        settings.mainModel = "small"
        XCTAssertEqual(settings.model(for: .notes).id, "small", "Notes follow the main model")
        XCTAssertEqual(settings.model(for: .dictation).id, "parakeet-v3")
        let reloaded = AppSettings(defaults: defaults)
        XCTAssertEqual(reloaded.model(for: .dictation).id, "parakeet-v3")
        XCTAssertEqual(reloaded.model(for: .files).id, "small")
        reloaded.setOwnModel("small", for: .dictation)
        XCTAssertNil(reloaded.ownModel(for: .dictation), "Choosing the main model clears the task's own choice")
        reloaded.setOwnModel("turbo", for: .files)
        reloaded.setOwnModel(nil, for: .files)
        XCTAssertNil(AppSettings(defaults: defaults).ownModel(for: .files))
    }

    func testTurboMovesToParakeetOnceWhenInstalled() {
        let defaults = UserDefaults(suiteName: "WhisperDropAppTests.\(UUID().uuidString)")!
        defaults.set("turbo", forKey: "mainModel")
        AppSettings(defaults: defaults).adoptParakeetDefault(installed: ["turbo"])
        XCTAssertEqual(AppSettings(defaults: defaults).mainModel, "turbo", "Parakeet is not installed")
        AppSettings(defaults: defaults).adoptParakeetDefault(installed: ["turbo", "parakeet-v3"])
        XCTAssertEqual(AppSettings(defaults: defaults).mainModel, "turbo", "The move is offered once")

        let migrating = UserDefaults(suiteName: "WhisperDropAppTests.\(UUID().uuidString)")!
        migrating.set("turbo", forKey: "mainModel")
        AppSettings(defaults: migrating).adoptParakeetDefault(installed: ["turbo", "parakeet-v3"])
        let moved = AppSettings(defaults: migrating)
        XCTAssertEqual(moved.mainModel, "parakeet-v3")
        moved.mainModel = "turbo"
        moved.adoptParakeetDefault(installed: ["turbo", "parakeet-v3"])
        XCTAssertEqual(AppSettings(defaults: migrating).mainModel, "turbo", "A later choice of Turbo stays")

        let chosen = UserDefaults(suiteName: "WhisperDropAppTests.\(UUID().uuidString)")!
        chosen.set("small", forKey: "mainModel")
        AppSettings(defaults: chosen).adoptParakeetDefault(installed: ["small", "parakeet-v3"])
        XCTAssertEqual(AppSettings(defaults: chosen).mainModel, "small")
    }

    func testUnsupportedLanguageFallsBackToAnInstalledWhisperModel() {
        let settings = AppSettings(defaults: UserDefaults(suiteName: "WhisperDropAppTests.\(UUID().uuidString)")!)
        settings.mainModel = "parakeet-v3"
        settings.spokenLanguage = "ja"
        XCTAssertEqual(settings.model(for: .dictation).id, "parakeet-v3", "Nothing to fall back to")
        settings.installedModels = { ["parakeet-v3", "small", "turbo-q8"] }
        XCTAssertEqual(settings.model(for: .dictation).id, "turbo-q8")
        XCTAssertEqual(settings.chosenModel(for: .dictation).id, "parakeet-v3")
        settings.spokenLanguage = "it"
        XCTAssertEqual(settings.model(for: .files).id, "parakeet-v3")
        settings.nextNoteLanguage = "ja"
        XCTAssertEqual(settings.model(for: .notes).id, "turbo-q8", "Notes use the next note's language")
        XCTAssertEqual(settings.model(for: .dictation).id, "parakeet-v3")
    }

    func testKeepModelReadyIsTheKeepLoadedResidency() {
        let defaults = UserDefaults(suiteName: "WhisperDropAppTests.\(UUID().uuidString)")!
        defaults.set(ModelResidency.thirtyMinutes.rawValue, forKey: "residency")
        defaults.set(true, forKey: "keepReady")
        let settings = AppSettings(defaults: defaults)
        XCTAssertEqual(settings.residency, .always, "The old switch becomes the residency")
        XCTAssertTrue(settings.keepReady)
        XCTAssertNil(defaults.object(forKey: "keepReady"))
        settings.keepReady = false
        XCTAssertEqual(settings.residency, .thirtyMinutes, "Turning it off restores the earlier choice")
        settings.residency = .twoMinutes
        settings.keepReady = true
        XCTAssertEqual(AppSettings(defaults: defaults).residency, .always)
        settings.keepReady = false
        XCTAssertEqual(settings.residency, .twoMinutes)
    }

    func testLiveTextSettingsFollowTheOldSwitch() {
        let off = UserDefaults(suiteName: "WhisperDropAppTests.\(UUID().uuidString)")!
        off.set(false, forKey: "livePreview")
        let settingsOff = AppSettings(defaults: off)
        XCTAssertEqual(settingsOff.dictationLiveText, .off)
        XCTAssertFalse(settingsOff.noteLiveText)
        let settings = AppSettings(defaults: UserDefaults(suiteName: "WhisperDropAppTests.\(UUID().uuidString)")!)
        XCTAssertEqual(settings.dictationLiveText, .inField)
        XCTAssertTrue(settings.noteLiveText)
    }

    private static func failed(_ state: NoteRecorder.State) -> Bool { if case .failed = state { true } else { false } }
}
