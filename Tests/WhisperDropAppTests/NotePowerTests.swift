import AppKit
import AVFoundation
import XCTest
import WhisperDropCore
@testable import WhisperDrop

@MainActor
final class NotePowerTests: XCTestCase {
    private final class Source: NoteCaptureSource {
        var onSamples: (@Sendable ([Float]) -> Void)?
        var onLevel: (@Sendable (Float) -> Void)?
        var droppedPacketCount = 0
        var failureMessage: String?
        var starts = 0
        var stops = 0
        var onStart: (() -> Void)?
        func start() throws { starts += 1; failureMessage = nil; onStart?(); onSamples?(Array(repeating: 0, count: 1600)) }
        func stop() { stops += 1 }
    }

    func testSleepStopsCaptureUntilExplicitResumeAndLidOpens() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let notifications = NotificationCenter()
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "NotePowerTests.\(UUID().uuidString)"))
        let settings = AppSettings(defaults: defaults)
        let host = ModelHost(tool: { _ in throw AppFailure("No test server") }, modelFile: { _ in root })
        let source = Source()
        var closed = false
        let factory = NoteCaptureFactory(makeMicrophone: { source }, makeSystemTap: { source }, makeWriter: { try AudioFileWriter(url: $0) },
                                         requestMicrophoneAccess: { true }, systemAudioSupported: { true })
        let recorder = NoteRecorder(settings: settings, host: host, folder: root, onFinish: { _ in }, captures: factory,
                                    defaults: defaults, sleepNotifications: notifications, lidIsClosed: { closed })
        defer { recorder.discard(); host.shutdown() }
        recorder.start(.microphone)
        for _ in 0..<100 where recorder.state != .recording { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(recorder.state, .recording)
        XCTAssertEqual(source.starts, 1)
        notifications.post(name: NSWorkspace.willSleepNotification, object: nil)
        XCTAssertEqual(recorder.state, .paused)
        XCTAssertEqual(source.stops, 1)
        XCTAssertNotNil(recorder.pauseReason)
        notifications.post(name: NSWorkspace.didWakeNotification, object: nil)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(recorder.state, .paused)
        XCTAssertEqual(source.starts, 1)
        closed = true
        recorder.resume()
        XCTAssertEqual(recorder.state, .paused)
        XCTAssertEqual(source.starts, 1)
        closed = false
        recorder.resume()
        XCTAssertEqual(recorder.state, .recording)
        XCTAssertEqual(source.starts, 2)
        XCTAssertNil(recorder.pauseReason)
        closed = true
        for _ in 0..<100 where recorder.state != .paused { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(recorder.state, .paused, "A closed lid must pause even when the Mac remains awake")
        XCTAssertEqual(source.stops, 2)
        closed = false
        recorder.resume()
        source.failureMessage = "Input device unavailable."
        for _ in 0..<100 where recorder.state != .paused { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(recorder.state, .paused)
        XCTAssertTrue(recorder.warning?.contains("Input device unavailable") == true)
        XCTAssertTrue(recorder.pauseReason?.contains("microphone stopped") == true)
        recorder.resume()
        XCTAssertEqual(recorder.state, .recording)
    }

    func testSleepDuringPermissionRequestDoesNotStartCaptureAfterWake() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let notifications = NotificationCenter()
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "NotePowerTests.\(UUID().uuidString)"))
        let settings = AppSettings(defaults: defaults)
        let host = ModelHost(tool: { _ in throw AppFailure("No test server") }, modelFile: { _ in root })
        let source = Source()
        var permission: CheckedContinuation<Bool, Never>?
        let factory = NoteCaptureFactory(makeMicrophone: { source }, makeSystemTap: { source }, makeWriter: { try AudioFileWriter(url: $0) },
                                         requestMicrophoneAccess: { await withCheckedContinuation { permission = $0 } }, systemAudioSupported: { true })
        var closed = false
        let recorder = NoteRecorder(settings: settings, host: host, folder: root, onFinish: { _ in }, captures: factory,
                                    defaults: defaults, sleepNotifications: notifications, lidIsClosed: { closed })
        defer { recorder.discard(); host.shutdown() }
        recorder.start(.microphone)
        for _ in 0..<100 where permission == nil { try await Task.sleep(for: .milliseconds(10)) }
        let pending = try XCTUnwrap(permission)
        closed = true
        for _ in 0..<100 where recorder.state != .paused { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(recorder.state, .paused)
        pending.resume(returning: true)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(recorder.state, .paused)
        XCTAssertEqual(source.starts, 0)
        closed = false
        recorder.resume()
        for _ in 0..<100 where recorder.state != .recording { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(recorder.state, .recording)
        XCTAssertEqual(source.starts, 1)
    }

    func testStoppingWhilePermissionIsPendingDoesNotWaitOrStartLater() async throws {
        for paused in [false, true] {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: root) }
            let notifications = NotificationCenter()
            let defaults = try XCTUnwrap(UserDefaults(suiteName: "NotePowerTests.\(UUID().uuidString)"))
            let host = ModelHost(tool: { _ in throw AppFailure("No test server") }, modelFile: { _ in root })
            let source = Source()
            var permission: CheckedContinuation<Bool, Never>?
            let factory = NoteCaptureFactory(makeMicrophone: { source }, makeSystemTap: { source }, makeWriter: { try AudioFileWriter(url: $0) },
                                             requestMicrophoneAccess: { await withCheckedContinuation { permission = $0 } }, systemAudioSupported: { true })
            let recorder = NoteRecorder(settings: AppSettings(defaults: defaults), host: host, folder: root,
                                        onFinish: { _ in XCTFail("No recording was started") }, captures: factory, defaults: defaults,
                                        sleepNotifications: notifications, lidIsClosed: { false })
            recorder.start(.microphone)
            for _ in 0..<100 where permission == nil { try await Task.sleep(for: .milliseconds(10)) }
            let pending = try XCTUnwrap(permission)
            if paused { notifications.post(name: NSWorkspace.willSleepNotification, object: nil) }
            recorder.stop()
            XCTAssertEqual(recorder.state, .idle)
            pending.resume(returning: true)
            try await Task.sleep(for: .milliseconds(50))
            XCTAssertEqual(recorder.state, .idle)
            XCTAssertEqual(source.starts, 0)
            host.shutdown()
        }
    }

    func testSleepWhileADeviceIsOpeningLeavesTheNotePaused() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let notifications = NotificationCenter()
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "NotePowerTests.\(UUID().uuidString)"))
        let host = ModelHost(tool: { _ in throw AppFailure("No test server") }, modelFile: { _ in root })
        let mic = Source(), system = Source()
        system.onStart = { notifications.post(name: NSWorkspace.willSleepNotification, object: nil) }
        let factory = NoteCaptureFactory(makeMicrophone: { mic }, makeSystemTap: { system }, makeWriter: { try AudioFileWriter(url: $0) },
                                         requestMicrophoneAccess: { true }, systemAudioSupported: { true })
        let recorder = NoteRecorder(settings: AppSettings(defaults: defaults), host: host, folder: root, onFinish: { _ in },
                                    captures: factory, defaults: defaults, sleepNotifications: notifications, lidIsClosed: { false })
        defer { recorder.discard(); host.shutdown() }
        recorder.start(.both)
        for _ in 0..<100 where system.starts == 0 { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(recorder.state, .paused)
        XCTAssertEqual(mic.stops, 1)
        XCTAssertEqual(system.stops, 1)
        XCTAssertNotNil(recorder.pauseReason)
        system.onStart = nil
        recorder.resume()
        XCTAssertEqual(recorder.state, .recording)
        XCTAssertEqual(mic.starts, 2)
        XCTAssertEqual(system.starts, 2)
    }

    func testStopWhileFirstDeviceIsOpeningCleansUpTheUnfinishedNote() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "NotePowerTests.\(UUID().uuidString)"))
        let host = ModelHost(tool: { _ in throw AppFailure("No test server") }, modelFile: { _ in root })
        let source = Source()
        let factory = NoteCaptureFactory(makeMicrophone: { source }, makeSystemTap: { source }, makeWriter: { try AudioFileWriter(url: $0) },
                                         requestMicrophoneAccess: { true }, systemAudioSupported: { true })
        let recorder = NoteRecorder(settings: AppSettings(defaults: defaults), host: host, folder: root,
                                    onFinish: { _ in XCTFail("The first device never opened") }, captures: factory,
                                    defaults: defaults, sleepNotifications: NotificationCenter(), lidIsClosed: { false })
        defer { recorder.discard(); host.shutdown() }
        source.onStart = { recorder.stop() }
        recorder.start(.microphone)
        for _ in 0..<100 where recorder.state != .idle { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(recorder.state, .idle)
        XCTAssertEqual(source.stops, 1)
        XCTAssertTrue((try? FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty) ?? true)
    }

    func testRepeatedSleepAndResumePreservesBothRecordings() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let notifications = NotificationCenter()
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "NotePowerTests.\(UUID().uuidString)"))
        let host = ModelHost(tool: { _ in throw AppFailure("No test server") }, modelFile: { _ in root })
        let mic = Source(), system = Source()
        var saved: TranscriptionJob?
        let factory = NoteCaptureFactory(makeMicrophone: { mic }, makeSystemTap: { system }, makeWriter: { try AudioFileWriter(url: $0) },
                                         requestMicrophoneAccess: { true }, systemAudioSupported: { true })
        let recorder = NoteRecorder(settings: AppSettings(defaults: defaults), host: host, folder: root,
                                    onFinish: { saved = $0 }, captures: factory, defaults: defaults,
                                    sleepNotifications: notifications, lidIsClosed: { false })
        defer { recorder.discard(); host.shutdown() }
        recorder.start(.both)
        for _ in 0..<100 where recorder.state != .recording { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(recorder.state, .recording)
        for _ in 0..<20 {
            notifications.post(name: NSWorkspace.willSleepNotification, object: nil)
            XCTAssertEqual(recorder.state, .paused)
            recorder.resume()
            XCTAssertEqual(recorder.state, .recording)
        }
        recorder.stop()
        for _ in 0..<500 where saved == nil { try await Task.sleep(for: .milliseconds(10)) }
        let audioFolder = try XCTUnwrap(saved?.audioFile)
        for name in ["you.m4a", "others.m4a"] {
            let audio = try AVAudioFile(forReading: audioFolder.appendingPathComponent(name))
            XCTAssertEqual(audio.length, 21 * 1600)
        }
        XCTAssertEqual(mic.starts, 21)
        XCTAssertEqual(system.starts, 21)
    }

    func testFailedCompressionKeepsAudioAndWarnsInSavedNote() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "NotePowerTests.\(UUID().uuidString)"))
        let host = ModelHost(tool: { _ in throw AppFailure("No test server") }, modelFile: { _ in root })
        let source = Source()
        var saved: TranscriptionJob?
        let factory = NoteCaptureFactory(makeMicrophone: { source }, makeSystemTap: { source }, makeWriter: { try AudioFileWriter(url: $0) },
                                         compressAudio: { _ in throw AppFailure("Test conversion failure") },
                                         requestMicrophoneAccess: { true }, systemAudioSupported: { true })
        let recorder = NoteRecorder(settings: AppSettings(defaults: defaults), host: host, folder: root, onFinish: { saved = $0 },
                                    captures: factory, defaults: defaults, sleepNotifications: NotificationCenter(), lidIsClosed: { false })
        defer { recorder.discard(); host.shutdown() }
        recorder.start(.microphone)
        for _ in 0..<100 where recorder.state != .recording { try await Task.sleep(for: .milliseconds(10)) }
        recorder.stop()
        for _ in 0..<500 where saved == nil { try await Task.sleep(for: .milliseconds(10)) }
        let job = try XCTUnwrap(saved)
        XCTAssertTrue(job.error?.contains("original audio was kept") == true)
        let folder = try XCTUnwrap(job.audioFile)
        XCTAssertEqual(try AVAudioFile(forReading: folder.appendingPathComponent("you.caf")).length, 1600)
    }
}
