import XCTest
import WhisperDropCore
@testable import WhisperDrop

/// Opt-in engine comparison through the real ModelHost. Silent: audio is read from files.
/// WHISPERDROP_ENGINE_SET is a folder with refs.jsonl and 16 kHz WAV files; results go to WHISPERDROP_ENGINE_REPORT as JSON lines.
/// Mode `dictation` follows DictationController: trim, speech gate, short-clip request, dictation text filter.
/// Mode `raw` sends each whole file as one note-style request with the silence check.
@MainActor
final class EngineReplayTests: XCTestCase {
    func testEngineReplay() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let set = env["WHISPERDROP_ENGINE_SET"], let report = env["WHISPERDROP_ENGINE_REPORT"] else {
            throw XCTSkip("Set WHISPERDROP_ENGINE_SET and WHISPERDROP_ENGINE_REPORT to compare engines")
        }
        executionTimeAllowance = 3600
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let models = URL(fileURLWithPath: env["WHISPERDROP_ENGINE_MODELS"] ?? repo.appendingPathComponent(".experiments/models").path)
        let model = try XCTUnwrap(TranscriptionModel.catalog.first { $0.id == (env["WHISPERDROP_ENGINE_MODEL"] ?? "turbo") })
        let dictation = (env["WHISPERDROP_ENGINE_MODE"] ?? "dictation") == "dictation"
        let host = ModelHost(tool: { repo.appendingPathComponent(".runtime/bin/\($0)") }, modelFile: { $0.location(in: models) },
                             processFile: URL(fileURLWithPath: report + ".pid"))
        defer { host.shutdown() }
        let loadStart = Date()
        try await host.ensureReady(model)
        let loadSeconds = Date().timeIntervalSince(loadStart)
        let folder = URL(fileURLWithPath: set)
        let lines = try String(contentsOf: folder.appendingPathComponent("refs.jsonl"), encoding: .utf8).split(separator: "\n")
        var output: [String] = []
        var peakRSS = 0
        for line in lines {
            let ref = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
            let id = try XCTUnwrap(ref["id"] as? String)
            let language = env["WHISPERDROP_ENGINE_LANGUAGE"] ?? (ref["lang"] as? String ?? "auto")
            let samples = try XCTUnwrap(WAVDecoder.pcm16(Data(contentsOf: folder.appendingPathComponent(id + ".wav")))).samples
            let begin = Date()
            var text = ""
            var gated = false
            if dictation {
                let trimmed = SpeechDetector.trimSilence(samples)
                if SpeechDetector.hasSpeech(trimmed) {
                    let result = try await host.transcribe(trimmed, model: model, language: language, shortClip: true)
                    text = HallucinationFilter.dictationText(result, vocabulary: "") ?? ""
                } else { gated = true }
            } else {
                let result = try await host.transcribe(samples, model: model, language: language)
                text = HallucinationFilter.clean(result.segments, removeNeighborRepeats: false, preserveShortClosings: true).map(\.text).joined(separator: " ")
            }
            let elapsed = Date().timeIntervalSince(begin)
            if let pid = host.serverProcessIdentifier { peakRSS = max(peakRSS, Self.residentKB(pid)) }
            let record: [String: Any] = ["id": id, "hyp": text, "seconds": Double(samples.count) / Double(whisperSampleRate),
                                         "decode": elapsed, "gated": gated, "repetition_retry": host.lastRepetitionRetry]
            output.append(String(decoding: try JSONSerialization.data(withJSONObject: record), as: UTF8.self))
        }
        try (output.joined(separator: "\n") + "\n").write(toFile: report, atomically: true, encoding: .utf8)
        let meta: [String: Any] = ["model": model.id, "mode": dictation ? "dictation" : "raw", "load_seconds": loadSeconds, "peak_server_rss_kb": peakRSS]
        try JSONSerialization.data(withJSONObject: meta, options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: report + ".meta.json"))
    }

    private static func residentKB(_ pid: pid_t) -> Int {
        let ps = Process()
        ps.executableURL = URL(fileURLWithPath: "/bin/ps")
        ps.arguments = ["-o", "rss=", "-p", String(pid)]
        let pipe = Pipe()
        ps.standardOutput = pipe
        guard (try? ps.run()) != nil else { return 0 }
        ps.waitUntilExit()
        return Int(String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
    }
}
