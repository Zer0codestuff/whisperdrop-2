import Foundation

public struct SpeechRange: Sendable, Equatable {
    public let start: Double
    public let end: Double
    public init(start: Double, end: Double) { self.start = start; self.end = end }
}

/// Checks short closing phrases against independent voice activity, without trimming lecture speech.
public enum SilenceGuard {
    public static func needsCheck(_ segments: [TranscriptSegment]) -> Bool {
        segments.contains { suspect($0.text) || trailingClosing($0) != nil }
    }

    public static func filter(_ segments: [TranscriptSegment], speech: [SpeechRange]) -> [TranscriptSegment] {
        segments.compactMap { segment in
            if suspect(segment.text) {
                return supported(start: segment.start, end: segment.end, speech: speech) ? segment : nil
            }
            guard let tail = trailingClosing(segment), let words = segment.words,
                  !supported(start: words[tail].start, end: words.last!.end, speech: speech) else { return segment }
            let kept = Array(words[..<tail])
            guard let last = kept.last else { return nil }
            var copy = segment
            copy.words = kept
            copy.end = last.end
            copy.text = kept.map(\.text).joined().trimmingCharacters(in: .whitespacesAndNewlines)
            return copy
        }
    }

    private static func supported(start: Double, end: Double, speech: [SpeechRange]) -> Bool {
        // Unknown or zero-length timing is not evidence of silence.
        guard start.isFinite, end.isFinite, end > start else { return true }
        return speech.contains { min(end + 0.12, $0.end) - max(start - 0.12, $0.start) >= 0.08 }
    }

    private static func trailingClosing(_ segment: TranscriptSegment) -> Int? {
        guard let words = segment.words, words.count >= 2,
              words.map(\.text).joined().trimmingCharacters(in: .whitespacesAndNewlines) == segment.text.trimmingCharacters(in: .whitespacesAndNewlines) else { return nil }
        for index in max(1, words.count - 4)..<words.count {
            guard suspect(words[index...].map(\.text).joined()),
                  words[index].start - words[index - 1].end >= 0.5 else { continue }
            return index
        }
        return nil
    }

    private static func suspect(_ text: String) -> Bool {
        let words = text.lowercased().folding(options: .diacriticInsensitive, locale: Locale(identifier: "en_US_POSIX"))
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
        guard !words.isEmpty, words.count <= 12 else { return false }
        let key = words.joined(separator: " ")
        if phrases.contains(key) { return true }
        return words.allSatisfy { singleWords.contains($0) }
    }

    private static let singleWords: Set<String> = ["grazie", "ciao", "arrivederci", "thanks", "bye", "goodbye"]
    private static let phrases: Set<String> = ["grazie mille", "grazie a tutti", "grazie per l attenzione", "alla prossima", "thank you", "thank you very much", "see you", "bye bye"]
}
