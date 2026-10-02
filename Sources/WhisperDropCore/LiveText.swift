import Foundation

/// Words recognized while audio keeps arriving, for live text in dictation and notes.
///
/// Each request decodes a short window that starts a little before the settled boundary, so the model has some
/// left context and requests stay short however long the speaker talks. A word settles once `settleAfter` seconds
/// of audio follow it inside a window. Settled words never change; the words after them are replaced by the next
/// request. Times are in seconds from the start of the recording.
public struct LiveText: Sendable {
    /// Audio decoded again before the settled boundary. Gives the first new words their sentence context;
    /// with 3 seconds, Parakeet sometimes switched Italian speech to English words.
    public var leftContext = 10.0
    /// A word settles when at least this much decoded audio follows it.
    public var settleAfter = 6.0
    /// Longest window for one live request.
    public var maxWindow = 30.0

    public private(set) var settled: [TranscriptWord] = []
    public private(set) var pending: [TranscriptWord] = []
    /// Audio before this time is represented by `settled`.
    public private(set) var settledUntil: Double

    public init(start: Double = 0) {
        settledUntil = start
    }

    /// Audio to decode next, given audio available from `audioStart` up to `end`. Nil when nothing new can be decoded.
    public func window(audioStart: Double, end: Double) -> Range<Double>? {
        let from = max(audioStart, settledUntil - leftContext)
        let to = min(end, from + maxWindow)
        guard to > settledUntil, to - from >= 0.3 else { return nil }
        return from..<to
    }

    /// Accepts words decoded from `window`. A final pass settles every word.
    public mutating func accept(_ words: [TranscriptWord], window: Range<Double>, final: Bool = false) {
        let fresh = newWords(words)
        if final {
            settled += fresh
            pending = []
            settledUntil = max(settledUntil, window.upperBound)
            return
        }
        let cutoff = window.upperBound - settleAfter
        var count = 0
        while count < fresh.count, fresh[count].end <= cutoff { count += 1 }
        if count > 0 {
            settled += fresh[..<count]
            let last = fresh[count - 1].end
            let next = count < fresh.count ? fresh[count].start : cutoff
            settledUntil = max(settledUntil, last + max(0, next - last) / 2)
        } else if fresh.isEmpty, cutoff > settledUntil {
            // Silence or noise. Move on so windows do not grow.
            settledUntil = cutoff
        }
        pending = Array(fresh[count...])
    }

    /// Words of a new request that follow the settled ones. The request re-hears up to `leftContext` seconds,
    /// and word times move by a frame or two between requests, so the last settled words are found again by spelling
    /// near their old time; everything after them is new. Without such a match the settled boundary time decides.
    private func newWords(_ words: [TranscriptWord]) -> [TranscriptWord] {
        let heard = words.filter { !Self.key($0.text).isEmpty }
        guard let last = settled.last else { return heard.filter { ($0.start + $0.end) / 2 >= settledUntil } }
        let tail = settled.suffix(3).map { Self.key($0.text) }
        for length in stride(from: tail.count, through: 1, by: -1) {
            let target = Array(tail.suffix(length))
            var best: (index: Int, distance: Double)?
            var index = 0
            while index + length <= heard.count {
                let distance = abs(heard[index + length - 1].start - last.start)
                if distance <= 0.5, (0..<length).allSatisfy({ Self.key(heard[index + $0].text) == target[$0] }),
                   best.map({ distance < $0.distance }) ?? true {
                    best = (index, distance)
                }
                index += 1
            }
            if let best { return Array(heard[(best.index + length)...]) }
        }
        return heard.filter { ($0.start + $0.end) / 2 >= settledUntil }
    }

    private static func key(_ text: String) -> String {
        String(text.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) })
    }

    /// Drops words centered before `time`. Notes call it once a chunk covering them is committed.
    public mutating func discard(through time: Double) {
        settled.removeAll { ($0.start + $0.end) / 2 < time }
        pending.removeAll { ($0.start + $0.end) / 2 < time }
        settledUntil = max(settledUntil, time)
    }

    public var settledText: String { Self.join(settled) }
    public var text: String { Self.join(settled + pending) }

    public static func join(_ words: [TranscriptWord]) -> String {
        words.map(\.text).joined().split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}

/// Plain text edits for live text written into another app.
public enum LiveTextEdit: Equatable, Sendable {
    /// Characters to delete from the end of `old` and the text to type after that.
    case replace(delete: Int, insert: String)

    /// Smallest end edit that turns `old` into `new`, counted in characters.
    public static func between(_ old: String, _ new: String) -> LiveTextEdit {
        let oldCharacters = Array(old), newCharacters = Array(new)
        var shared = 0
        while shared < oldCharacters.count, shared < newCharacters.count, oldCharacters[shared] == newCharacters[shared] { shared += 1 }
        return .replace(delete: oldCharacters.count - shared, insert: String(newCharacters[shared...]))
    }
}
