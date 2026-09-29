import Foundation

/// Contract file. Signatures are fixed; bodies are implemented by the core worker.

/// Result of one whisper-server request.
public struct ServerTranscription: Sendable {
    public var segments: [TranscriptSegment]
    public var language: String?
    public init(segments: [TranscriptSegment], language: String?) {
        self.segments = segments; self.language = language
    }
    public var text: String { segments.map(\.text).joined(separator: " ") }
}

public extension TranscriptOutput {
    /// Parses a whisper-server `verbose_json` response. Segment times are shifted by `offset` seconds and tagged with `speaker`.
    static func parseServer(_ data: Data, offset: Double = 0, speaker: Speaker? = nil) throws -> ServerTranscription {
        ServerTranscription(segments: [], language: nil)
    }
    /// Plain text; when segments carry speakers, consecutive lines by the same speaker are grouped under "You:" / "Others:" labels.
    static func labeledText(_ segments: [TranscriptSegment]) -> String {
        segments.map(\.text).joined(separator: "\n")
    }
}

public enum HallucinationFilter {
    /// Removes known silence hallucinations, empty and bracketed non-speech segments, and runs of repeated text.
    public static func clean(_ segments: [TranscriptSegment]) -> [TranscriptSegment] { segments }
    /// Cleans dictation output into one line of text ready to insert. Returns nil when nothing meaningful was said.
    public static func dictationText(_ transcription: ServerTranscription) -> String? {
        let text = transcription.text.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }
}

public enum TranscriptMerger {
    /// Merges both speakers by start time and renumbers ids. Drops "You" segments that overlap and closely match an "Others" segment (speaker echo).
    public static func merge(you: [TranscriptSegment], others: [TranscriptSegment]) -> [TranscriptSegment] {
        (you + others).sorted { $0.start < $1.start }
    }
    /// Normalized similarity of two texts, 0...1.
    public static func similarity(_ a: String, _ b: String) -> Double { a == b ? 1 : 0 }
}
