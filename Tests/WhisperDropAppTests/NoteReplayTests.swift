import AVFoundation
import XCTest
import WhisperDropCore
@testable import WhisperDrop

/// Opt-in local experiment. Feeds the production chunker in 500 ms capture ticks.
/// Audio, models and reports are supplied through environment variables and never added to Git.
@MainActor
final class NoteReplayTests: XCTestCase {
    func testReplay() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let input = env["WHISPERDROP_REPLAY_AUDIO"], let output = env["WHISPERDROP_REPLAY_REPORT"] else {
            throw XCTSkip("Set WHISPERDROP_REPLAY_AUDIO and WHISPERDROP_REPLAY_REPORT to run a local replay")
        }
        executionTimeAllowance = 3600
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let models = URL(fileURLWithPath: env["WHISPERDROP_REPLAY_MODELS"] ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/WhisperDrop 2/Models").path)
        let model = try XCTUnwrap(TranscriptionModel.catalog.first { $0.id == (env["WHISPERDROP_REPLAY_MODEL"] ?? "turbo") })
        let policy = env["WHISPERDROP_REPLAY_POLICY"] ?? "lecture"
        let legacy = policy == "legacy"
        let language = env["WHISPERDROP_REPLAY_LANGUAGE"] ?? "it"
        let vocabulary = env["WHISPERDROP_REPLAY_VOCABULARY"] ?? ""
        let noContext = env["WHISPERDROP_REPLAY_NO_CONTEXT"] == "1"
        let audioBoost = env["WHISPERDROP_REPLAY_AUDIO_BOOST"] == "1"
        let checkSilence = env["WHISPERDROP_REPLAY_SILENCE_CHECK"] != "0"
        let startSeconds = Double(env["WHISPERDROP_REPLAY_START"] ?? "0") ?? 0
        let duration = Double(env["WHISPERDROP_REPLAY_DURATION"] ?? "inf") ?? .infinity
        let host = ModelHost(tool: { root.appendingPathComponent(".runtime/bin/\($0)") },
                             modelFile: { models.appendingPathComponent($0.filename) },
                             processFile: URL(fileURLWithPath: output + ".pid"), preserveWords: !legacy)
        defer { host.shutdown() }
        let loadStart = Date()
        try await host.ensureReady(model)
        let loadSeconds = Date().timeIntervalSince(loadStart)
        let file = try AVAudioFile(forReading: URL(fileURLWithPath: input))
        XCTAssertEqual(file.processingFormat.sampleRate, Double(whisperSampleRate))
        XCTAssertEqual(file.processingFormat.channelCount, 1)
        file.framePosition = AVAudioFramePosition(startSeconds * Double(whisperSampleRate))
        var chunker: Chunker = (legacy || policy == "legacy-no-wrap") ? Chunker() : .lecture
        if policy == "balanced" {
            var options = Chunker.Options.lecture
            options.searchStart = 15; options.cutAfter = 35
            chunker = Chunker(target: 30, maxLength: 60, minLength: 15, options: options)
        }
        if policy == "no-overlap" {
            var options = Chunker.Options.lecture
            options.overlap = 0; options.unsettledTail = 0
            chunker = Chunker(target: 45, maxLength: 60, minLength: 15, options: options)
        }
        var chunks: [(AudioChunk, Double)] = []
        var fed = 0
        let limit = duration.isFinite ? Int(duration * Double(whisperSampleRate)) : Int.max
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 8_000))
        while file.framePosition < file.length && fed < limit {
            try file.read(into: buffer, frameCount: AVAudioFrameCount(min(8_000, limit - fed)))
            let count = Int(buffer.frameLength)
            guard count > 0 else { break }
            let samples = Array(UnsafeBufferPointer(start: try XCTUnwrap(buffer.floatChannelData?[0]), count: count))
            fed += count
            let available = Double(fed) / Double(whisperSampleRate)
            chunks += chunker.append(samples).map { ($0, available) }
        }
        let seconds = Double(fed) / Double(whisperSampleRate)
        if let tail = chunker.flush() { chunks.append((tail, seconds)) }
        var state = NoteTranscriptState()
        var legacySegments: [TranscriptSegment] = []
        var previous = ""
        var pinned: String?
        var requests: [[String: Any]] = []
        var totalInference = 0.0
        var totalPreprocessing = 0.0
        var boostedRequests = 0
        var virtualFinish = 0.0
        var maxRSSKB = 0
        for (index, entry) in chunks.enumerated() {
            let (chunk, available) = entry
            let recent = legacy ? previous : state.text(for: .microphone)
            let prompt = NotePrompt.prompt(previousText: noContext ? "" : recent, chunkDuration: chunk.duration, vocabulary: vocabulary)
            let requestLanguage = NoteLanguage.requestCode(setting: language, pinned: legacy ? pinned : state.pinnedLanguage)
            let begin = Date()
            let result = try await host.transcribe(chunk.samples, model: model, language: requestLanguage, prompt: prompt, offset: chunk.start, checkSilence: checkSilence, boostQuietAudio: audioBoost)
            let preprocessingSeconds = host.lastPreprocessingSeconds
            totalPreprocessing += preprocessingSeconds
            if host.lastAudioGain > 1 { boostedRequests += 1 }
            let elapsed = Date().timeIntervalSince(begin)
            totalInference += elapsed
            virtualFinish = max(virtualFinish, available) + elapsed
            if legacy {
                if pinned == nil, let detected = result.language { pinned = NoteLanguage.whisperCode(for: detected) }
                let cleaned = HallucinationFilter.clean(result.segments)
                legacySegments += cleaned
                previous = cleaned.isEmpty ? "" : previous + " " + cleaned.map(\.text).joined(separator: " ")
            } else {
                _ = state.accept(result, stream: .microphone, languageSetting: language, chunk: chunk)
            }
            if let pid = host.serverProcessIdentifier {
                let ps = Process(); ps.executableURL = URL(fileURLWithPath: "/bin/ps")
                ps.arguments = ["-o", "rss=", "-p", String(pid)]
                let pipe = Pipe(); ps.standardOutput = pipe
                try ps.run(); ps.waitUntilExit()
                let rss = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                maxRSSKB = max(maxRSSKB, Int(rss.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0)
            }
            requests.append(["start": chunk.start, "duration": chunk.duration, "stable_until": chunk.stableUntil ?? chunk.start + chunk.duration,
                             "available_at": available, "inference_seconds": elapsed, "response_segments": result.segments.count,
                             "preprocessing_seconds": preprocessingSeconds, "gain": host.lastAudioGain,
                             "repetition_retry": host.lastRepetitionRetry,
                             "text": result.text])
            print("Replay \(index + 1)/\(chunks.count), \(model.id), \(String(format: "%.1f", elapsed)) s")
        }
        let segments = legacy ? NoteJobs.renumber(legacySegments) : state.segments
        let text = legacy ? segments.map(\.text).joined(separator: "\n") : TranscriptOutput.labeledText(segments)
        let encoded = try JSONEncoder().encode(segments)
        let report: [String: Any] = ["policy": policy, "model": model.id, "language": language,
                                     "audio_boost": audioBoost, "silence_check": checkSilence,
                                     "preprocessing_seconds": totalPreprocessing, "boosted_requests": boostedRequests,
                                     "repetition_retries": requests.filter { $0["repetition_retry"] as? Bool == true }.count,
                                     "vocabulary": vocabulary, "audio_seconds": seconds, "load_seconds": loadSeconds,
                                     "inference_seconds": totalInference, "real_time_factor": totalInference / max(1, seconds),
                                     "simulated_finish_seconds": virtualFinish, "max_post_request_rss_kb": maxRSSKB,
                                     "requests": requests, "segments": try JSONSerialization.jsonObject(with: encoded), "transcript": text]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: output))
        try text.write(toFile: output + ".txt", atomically: true, encoding: .utf8)
        if policy != "legacy" && policy != "legacy-no-wrap" { XCTAssertFalse(text.isEmpty) }
    }
}
