import Foundation
import WhisperDropCore

@MainActor
enum SpeechActivityDetector {
    static func ranges(wav: Data, executable: URL, offset: Double) async throws -> [SpeechRange] {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("WhisperDrop-vad-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("audio.wav")
        try wav.write(to: file)
        return try await ranges(file: file, executable: executable, offset: offset)
    }

    static func ranges(file: URL, executable: URL, offset: Double = 0) async throws -> [SpeechRange] {
        let model = executable.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("models/ggml-silero-v6.2.0.bin")
        let result = try await CommandRunner().run(executable, ["--vad-model", model.path, "--file", file.path,
            "--vad-threshold", "0.35", "--vad-min-speech-duration-ms", "200", "--vad-min-silence-duration-ms", "100",
            "--vad-speech-pad-ms", "100", "--threads", "2", "--no-prints"], timeout: 30)
        guard result.status == 0 else { throw AppFailure("The local speech check could not read this audio.") }
        return try parse(result.stdout, offset: offset)
    }

    static func parse(_ text: String, offset: Double = 0) throws -> [SpeechRange] {
        guard let header = text.firstMatch(of: #/Detected ([0-9]+) speech segments:/#),
              let expected = Int(header.1) else { throw AppFailure("The local speech check returned invalid timing.") }
        var ranges: [SpeechRange] = []
        for line in text.components(separatedBy: .newlines) where line.hasPrefix("Speech segment ") {
            guard let match = line.firstMatch(of: #/start = ([0-9.]+), end = ([0-9.]+)/#),
                  let start = Double(match.1), let end = Double(match.2), start.isFinite, end.isFinite, end > start else {
                throw AppFailure("The local speech check returned invalid timing.")
            }
            // This pinned whisper.cpp tool prints centiseconds, despite its README examples.
            ranges.append(SpeechRange(start: start / 100 + offset, end: end / 100 + offset))
        }
        guard ranges.count == expected else { throw AppFailure("The local speech check returned incomplete timing.") }
        return ranges
    }
}
