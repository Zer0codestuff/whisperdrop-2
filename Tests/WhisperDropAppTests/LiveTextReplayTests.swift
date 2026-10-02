import XCTest
import WhisperDropCore
@testable import WhisperDrop

/// Opt-in comparison of live dictation text with the usual whole-clip decode, through the real ModelHost.
/// Silent: audio is read from files. Each long file is cut at pauses into dictations of about
/// WHISPERDROP_LIVE_PIECE seconds. For every dictation the test decodes it whole, as dictation does without live text,
/// and replays the live loop: a request every 0.8 s or when the previous one returns, as DictationController does,
/// then the final request for the audio after the settled words.
/// WHISPERDROP_LIVE_SET is a folder with refs.jsonl and 16 kHz WAV files. Results go to WHISPERDROP_LIVE_REPORT,
/// as `full/<set>.jsonl`, `live/<set>.jsonl` (one line per file, joined dictations) and `pieces.jsonl`.
@MainActor
final class LiveTextReplayTests: XCTestCase {
    func testLiveTextReplay() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let set = env["WHISPERDROP_LIVE_SET"], let report = env["WHISPERDROP_LIVE_REPORT"] else {
            throw XCTSkip("Set WHISPERDROP_LIVE_SET and WHISPERDROP_LIVE_REPORT to replay live dictation text")
        }
        executionTimeAllowance = 7200
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let models = URL(fileURLWithPath: env["WHISPERDROP_LIVE_MODELS"] ?? repo.appendingPathComponent(".experiments/models").path)
        let model = try XCTUnwrap(TranscriptionModel.catalog.first { $0.id == (env["WHISPERDROP_LIVE_MODEL"] ?? "parakeet-v3") })
        let pieceTarget = Double(env["WHISPERDROP_LIVE_PIECE"] ?? "60") ?? 60
        let output = URL(fileURLWithPath: report, isDirectory: true)
        let host = ModelHost(tool: { repo.appendingPathComponent(".runtime/bin/\($0)") }, modelFile: { $0.location(in: models) },
                             processFile: output.appendingPathComponent("server.pid"))
        defer { host.shutdown() }
        try FileManager.default.createDirectory(at: output.appendingPathComponent("full"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: output.appendingPathComponent("live"), withIntermediateDirectories: true)
        try await host.ensureReady(model)
        let folder = URL(fileURLWithPath: set)
        let setName = folder.lastPathComponent
        let lines = try String(contentsOf: folder.appendingPathComponent("refs.jsonl"), encoding: .utf8).split(separator: "\n")
        var fullLines: [String] = [], liveLines: [String] = [], pieceLines: [String] = []
        let only = env["WHISPERDROP_LIVE_IDS"].map { Set($0.split(separator: ",").map(String.init)) }
        for line in lines {
            let ref = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
            let id = try XCTUnwrap(ref["id"] as? String)
            if let only, !only.contains(id) { continue }
            let language = env["WHISPERDROP_LIVE_LANGUAGE"] ?? (ref["lang"] as? String ?? "auto")
            let samples = try XCTUnwrap(WAVDecoder.pcm16(Data(contentsOf: folder.appendingPathComponent(id + ".wav")))).samples
            var fullTexts: [String] = [], liveTexts: [String] = []
            var fullDecode = 0.0, liveDecode = 0.0
            for (index, range) in Self.pieces(samples, target: pieceTarget).enumerated() {
                let piece = Array(samples[range])
                let duration = Double(piece.count) / Double(whisperSampleRate)
                // Whole clip, as dictation without live text.
                var started = Date()
                var full = ""
                let trimmed = SpeechDetector.trimSilence(piece)
                if SpeechDetector.hasSpeech(trimmed) {
                    let result = try await host.transcribe(trimmed, model: model, language: language, shortClip: true)
                    full = HallucinationFilter.dictationText(result, vocabulary: "") ?? ""
                }
                let fullSeconds = Date().timeIntervalSince(started)
                // Live loop on recording time.
                var live = Self.liveText(env)
                var clock = 0.0, requests = 0, busy = 0.0
                var lags: [Double] = []
                while true {
                    clock += 0.8
                    guard clock < duration else { break }
                    guard let window = live.window(audioStart: 0, end: clock) else { continue }
                    let audio = DictationController.slice(piece, window)
                    var words: [TranscriptWord] = []
                    started = Date()
                    if SpeechDetector.hasSpeech(audio) {
                        words = try await host.transcribe(audio, model: model, language: language, offset: window.lowerBound, checkSilence: false).timedWords
                        requests += 1
                    }
                    let spent = Date().timeIntervalSince(started)
                    busy += spent
                    live.accept(words, window: window)
                    // A slow request delays the next one, as in the app.
                    clock += max(0, spent - 0.8)
                    lags.append(clock - live.settledUntil)
                }
                started = Date()
                let window = max(0, live.settledUntil - live.leftContext)..<max(duration, live.settledUntil)
                let tail = DictationController.slice(piece, window)
                var text: String
                if live.settled.isEmpty {
                    text = full
                } else {
                    if SpeechDetector.hasSpeech(tail) {
                        live.accept(try await host.transcribe(tail, model: model, language: language, offset: window.lowerBound, shortClip: true).timedWords,
                                    window: window, final: true)
                    } else { live.accept([], window: window, final: true) }
                    let joined = TranscriptSegment(id: 0, start: 0, end: duration, text: live.settledText, words: live.settled)
                    text = HallucinationFilter.dictationText(ServerTranscription(segments: [joined], language: nil), vocabulary: "") ?? ""
                }
                let finalSeconds = live.settled.isEmpty ? fullSeconds : Date().timeIntervalSince(started)
                fullTexts.append(full); liveTexts.append(text)
                fullDecode += fullSeconds; liveDecode += busy + finalSeconds
                let record: [String: Any] = ["id": id, "piece": index, "seconds": duration, "full": full, "live": text,
                                             "full_latency": fullSeconds, "live_final_latency": finalSeconds, "requests": requests,
                                             "busy": busy, "median_settle_lag": Self.median(lags), "max_settle_lag": lags.max() ?? 0]
                pieceLines.append(String(decoding: try JSONSerialization.data(withJSONObject: record), as: UTF8.self))
            }
            let seconds = Double(samples.count) / Double(whisperSampleRate)
            for (texts, decode, into) in [(fullTexts, fullDecode, 0), (liveTexts, liveDecode, 1)] {
                let record: [String: Any] = ["id": id, "hyp": texts.joined(separator: " "), "seconds": seconds, "decode": decode]
                let json = String(decoding: try JSONSerialization.data(withJSONObject: record), as: UTF8.self)
                if into == 0 { fullLines.append(json) } else { liveLines.append(json) }
            }
        }
        try (fullLines.joined(separator: "\n") + "\n").write(to: output.appendingPathComponent("full/\(setName).jsonl"), atomically: true, encoding: .utf8)
        try (liveLines.joined(separator: "\n") + "\n").write(to: output.appendingPathComponent("live/\(setName).jsonl"), atomically: true, encoding: .utf8)
        try (pieceLines.joined(separator: "\n") + "\n").write(to: output.appendingPathComponent("pieces.jsonl"), atomically: true, encoding: .utf8)
    }

    /// Default settings, or the values in WHISPERDROP_LIVE_LEFT, _SETTLE and _WINDOW for tuning.
    private static func liveText(_ env: [String: String]) -> LiveText {
        var live = LiveText()
        if let value = env["WHISPERDROP_LIVE_LEFT"].flatMap(Double.init) { live.leftContext = value }
        if let value = env["WHISPERDROP_LIVE_SETTLE"].flatMap(Double.init) { live.settleAfter = value }
        if let value = env["WHISPERDROP_LIVE_WINDOW"].flatMap(Double.init) { live.maxWindow = value }
        return live
    }

    /// Cuts at the quietest 50 ms block within 15 seconds of each target length.
    private static func pieces(_ samples: [Float], target: Double) -> [Range<Int>] {
        let rms = LongAudioPlan.blockRMS(samples[...])
        let block = LongAudioPlan.blockSize
        var result: [Range<Int>] = []
        var start = 0
        while samples.count - start > Int((target + 15) * Double(whisperSampleRate)) {
            let low = (start + Int((target - 15) * Double(whisperSampleRate))) / block
            let high = (start + Int((target + 15) * Double(whisperSampleRate))) / block
            let quietest = (low..<min(high, rms.count)).min { rms[$0] < rms[$1] } ?? low
            let cut = quietest * block + block / 2
            result.append(start..<cut)
            start = cut
        }
        result.append(start..<samples.count)
        return result
    }

    private static func median(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        return sorted[sorted.count / 2]
    }
}
