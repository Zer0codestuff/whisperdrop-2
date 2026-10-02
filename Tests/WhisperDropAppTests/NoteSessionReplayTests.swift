import AVFoundation
import XCTest
import WhisperDropCore
@testable import WhisperDrop

/// Silent replay through the capture queue, resampler, writer, recorder and real model host.
@MainActor
final class NoteSessionReplayTests: XCTestCase {
    func testRecordedSessionReplay() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let input = env["WHISPERDROP_SESSION_AUDIO"], let report = env["WHISPERDROP_SESSION_REPORT"] else {
            throw XCTSkip("Set WHISPERDROP_SESSION_AUDIO and WHISPERDROP_SESSION_REPORT for a silent session replay")
        }
        let pace = Double(env["WHISPERDROP_SESSION_SPEED"] ?? "1") ?? 1
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let folder = URL(fileURLWithPath: report + ".recordings", isDirectory: true)
        let models = env["WHISPERDROP_SESSION_MODELS"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/WhisperDrop 2/Models")
        let host = ModelHost(tool: { repo.appendingPathComponent(".runtime/bin/\($0)") }, modelFile: { $0.location(in: models) },
                             processFile: URL(fileURLWithPath: report + ".pid"))
        defer { host.shutdown() }
        let suite = "WhisperDrop.SessionReplay.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)
        settings.spokenLanguage = env["WHISPERDROP_SESSION_LANGUAGE"] ?? "it"
        settings.mainModel = env["WHISPERDROP_SESSION_MODEL"] ?? "turbo"
        settings.noteVocabulary = env["WHISPERDROP_SESSION_VOCABULARY"] ?? ""
        settings.keepNoteAudio = env["WHISPERDROP_SESSION_KEEP_AUDIO"] != "0"
        settings.automaticAudioBoost = env["WHISPERDROP_SESSION_AUDIO_BOOST"] != "0"
        settings.noteLiveText = env["WHISPERDROP_SESSION_LIVE_PREVIEW"] != "0"
        let source = try ReplayCapture(file: URL(fileURLWithPath: input), speed: pace)
        var saved: TranscriptionJob?
        let factory = NoteCaptureFactory(makeMicrophone: { source }, makeSystemTap: { source }, makeWriter: { try AudioFileWriter(url: $0) },
                                         requestMicrophoneAccess: { true }, systemAudioSupported: { true })
        let recorder = NoteRecorder(settings: settings, host: host, folder: folder, onFinish: { saved = $0 }, captures: factory, defaults: defaults,
            folderProvider: { (audio: folder.appendingPathComponent("Audio"), transcripts: folder.appendingPathComponent("Transcripts")) })
        defer { if recorder.state != .idle { recorder.finishForTermination() } }
        source.onEnd = { [weak recorder] in Task { @MainActor in recorder?.stop() } }
        let started = Date()
        recorder.start(.microphone)
        let deadline = Date().addingTimeInterval(source.duration / max(0.01, pace) + source.duration + 120)
        var previews: [[String: Any]] = []
        var lastPreview: [NoteLivePreview] = []
        var lastSegmentCount = 0
        var segmentEvents: [[String: Any]] = []
        while saved == nil && Date() < deadline {
            if case .failed(let error) = recorder.state { XCTFail(error); break }
            let wall = Date().timeIntervalSince(started)
            if recorder.livePreview != lastPreview {
                lastPreview = recorder.livePreview
                previews.append(["wall": wall, "recording_seconds": recorder.elapsed, "text": lastPreview.map(\.text).joined(separator: " ")])
            }
            if recorder.segments.count != lastSegmentCount {
                lastSegmentCount = recorder.segments.count
                segmentEvents.append(["wall": wall, "recording_seconds": recorder.elapsed, "segments": lastSegmentCount,
                                      "last_end": recorder.segments.last?.end ?? 0])
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        let job = try XCTUnwrap(saved, "Session did not finish")
        XCTAssertEqual(source.droppedPacketCount, 0)
        XCTAssertEqual(recorder.state, .idle)
        XCTAssertNil(job.error)
        XCTAssertFalse(job.segments.isEmpty)
        XCTAssertEqual(job.duration ?? 0, source.duration / max(0.01, pace), accuracy: 1)
        XCTAssertEqual(job.source.deletingLastPathComponent().lastPathComponent, "Transcripts")
        let audio = folder.appendingPathComponent("Audio/\(job.source.lastPathComponent)/\(NoteCopy.microphoneFile)")
        if settings.keepNoteAudio {
            let file = try AVAudioFile(forReading: audio)
            XCTAssertEqual(file.length, AVAudioFramePosition(source.sampleCount))
            XCTAssertNotNil(job.audioFile)
            let original = try AVAudioFile(forReading: URL(fileURLWithPath: input))
            let expected = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: original.processingFormat, frameCapacity: AVAudioFrameCount(original.length)))
            let actual = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)))
            try original.read(into: expected); try file.read(into: actual)
            let expectedSamples = Array(UnsafeBufferPointer(start: try XCTUnwrap(expected.floatChannelData?[0]), count: Int(expected.frameLength)))
            let actualSamples = Array(UnsafeBufferPointer(start: try XCTUnwrap(actual.floatChannelData?[0]), count: Int(actual.frameLength)))
            // CAF PCM16 rounds into 32767; one quantization step is allowed, not an amplified recording.
            XCTAssertEqual(actualSamples.count, expectedSamples.count)
            XCTAssertLessThanOrEqual(zip(actualSamples, expectedSamples).map { abs($0 - $1) }.max() ?? 0, 1.0 / 32768)
        } else {
            XCTAssertFalse(FileManager.default.fileExists(atPath: audio.path))
            XCTAssertNil(job.audioFile)
        }
        let encoded = try JSONEncoder().encode(job)
        var data = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        data["replay_audio_seconds"] = source.duration
        data["wall_seconds"] = Date().timeIntervalSince(started)
        data["speed"] = pace
        data["dropped_packets"] = source.droppedPacketCount
        data["live_previews"] = previews
        data["segment_events"] = segmentEvents
        try JSONSerialization.data(withJSONObject: data, options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: report))
    }
}

/// Test source uses the same PCM handoff and converter as the microphone, without opening a device.
private final class ReplayCapture: NoteCaptureSource, @unchecked Sendable {
    var onSamples: (@Sendable ([Float]) -> Void)?
    var onLevel: (@Sendable (Float) -> Void)?
    var onEnd: (@Sendable () -> Void)?
    var droppedPacketCount: Int { handoff?.droppedPacketCount ?? 0 }
    let sampleCount: Int
    var duration: Double { Double(sampleCount) / 16_000 }
    private let file: AVAudioFile
    private let buffer: AVAudioPCMBuffer
    private let speed: Double
    private let queue = DispatchQueue(label: "whisperdrop.test-replay")
    private var timer: DispatchSourceTimer?
    private var handoff: PCMSlotQueue?
    private let resampler = Mono16kResampler()

    init(file url: URL, speed: Double) throws {
        file = try AVAudioFile(forReading: url)
        guard file.processingFormat.sampleRate == 16_000, file.processingFormat.channelCount == 1,
              let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 320) else {
            throw AppFailure("Replay needs a 16 kHz mono file.")
        }
        self.buffer = buffer; self.speed = speed; sampleCount = Int(file.length)
    }

    func start() throws {
        handoff = PCMSlotQueue(payloadCapacity: 16_384, label: "whisperdrop.test-replay-pcm") { [weak self] packet in
            guard let self, let buffer = PCMBuffers.make(packet) else { return }
            let samples = self.resampler.convert(buffer: buffer)
            if !samples.isEmpty {
                self.onSamples?(samples)
                self.onLevel?(CaptureLevel.rms(samples[...]))
            }
        }
        handoff?.start()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + .milliseconds(100), repeating: max(0.0001, 0.02 / max(0.01, speed)))
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            do {
                try self.file.read(into: self.buffer, frameCount: 320)
                if self.buffer.frameLength > 0 { self.handoff?.publish(self.buffer) }
                else {
                    self.timer?.cancel()
                    self.onEnd?()
                }
            } catch {
                self.timer?.cancel()
                self.onEnd?()
            }
        }
        self.timer = timer
        timer.resume()
    }

    func stop() {
        queue.sync { timer?.cancel(); timer = nil }
        handoff?.stop()
        let tail = resampler.flush()
        if !tail.isEmpty { onSamples?(tail) }
    }
}
