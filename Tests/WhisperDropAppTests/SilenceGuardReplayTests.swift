import AVFoundation
import XCTest
import WhisperDropCore
@testable import WhisperDrop

/// Optional real-model controls. Generated fixtures are silent files, never played or published.
@MainActor
final class SilenceGuardReplayTests: XCTestCase {
    func testRealItalianClosingsSurviveAndNonSpeechClosingsAreRemoved() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let directory = env["WHISPERDROP_SILENCE_FIXTURES"] else { throw XCTSkip("Set WHISPERDROP_SILENCE_FIXTURES for local voice and noise controls") }
        let fixtures = URL(fileURLWithPath: directory)
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let models = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/WhisperDrop 2/Models")
        let host = ModelHost(tool: { repo.appendingPathComponent(".runtime/bin/\($0)") }, modelFile: { $0.location(in: models) },
                             processFile: fixtures.appendingPathComponent("control.pid"))
        defer { host.shutdown() }
        let model = try XCTUnwrap(TranscriptionModel.catalog.first { $0.id == "turbo" })
        var reports: [[String: Any]] = []
        for name in ["closings", "closings-quiet", "thanks-quiet", "hello-quiet", "silence", "room-noise", "repeated", "repeated-quiet"] {
            let file = try AVAudioFile(forReading: fixtures.appendingPathComponent(name + ".wav"))
            let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)))
            try file.read(into: buffer)
            let raw = Array(UnsafeBufferPointer(start: try XCTUnwrap(buffer.floatChannelData?[0]), count: Int(buffer.frameLength)))
            let result = try await host.transcribe(raw, model: model, language: "it", checkSilence: false, boostQuietAudio: true)
            let speech = try await SpeechActivityDetector.ranges(wav: WAVEncoder.pcm16(raw), executable: repo.appendingPathComponent(".runtime/bin/whisper-vad-speech-segments"), offset: 0)
            let filtered = SilenceGuard.filter(result.segments, speech: speech)
            let text = HallucinationFilter.clean(filtered, removeNeighborRepeats: false, preserveShortClosings: true).map(\.text).joined(separator: " ")
            if name.hasPrefix("repeated") {
                let normalized = text.lowercased().split { !$0.isLetter }.joined(separator: " ")
                let phrase = "la scala ordinale stabilisce un ordine tra le categorie"
                let baseline = try await host.transcribe(raw, model: model, language: "it", checkSilence: false)
                let recognized = baseline.text.lowercased().split { !$0.isLetter }.joined(separator: " ")
                XCTAssertGreaterThan(recognized.components(separatedBy: phrase).count - 1, 0)
                XCTAssertEqual(normalized.components(separatedBy: phrase).count - 1,
                               recognized.components(separatedBy: phrase).count - 1, "The app lost repeats retained by Whisper: \(name), \(text)")
            } else if name.hasPrefix("closings") || name == "thanks-quiet" || name == "hello-quiet" {
                if name != "hello-quiet" { XCTAssertTrue(text.lowercased().contains("grazie"), "Real thanks was lost: \(name), \(text)") }
                if name != "thanks-quiet" { XCTAssertTrue(text.lowercased().contains("ciao"), "Real greeting was lost: \(name), \(text)") }
            } else {
                XCTAssertFalse(SilenceGuard.needsCheck(filtered), "An unsupported closing survived: \(name), \(text)")
            }
            reports.append(["fixture": name, "gain": host.lastAudioGain, "repetition_retry": host.lastRepetitionRetry, "before": result.text, "after": text,
                            "segments_removed": result.segments.count - filtered.count, "speech_ranges": speech.count])
        }
        try JSONSerialization.data(withJSONObject: reports, options: [.prettyPrinted, .sortedKeys]).write(to: fixtures.appendingPathComponent("silence-controls.json"))
    }
}
