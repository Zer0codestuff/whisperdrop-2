import Foundation

/// Detects sustained decoder loops for a fresh inference attempt, without deleting repeated speech.
public enum RepetitionGuard {
    public static func score(_ text: String) -> Double {
        let words = tokens(text)
        guard words.count >= 24 else { return 0 }
        var counts: [String: Int] = [:]
        for index in 0...(words.count - 4) {
            counts[words[index..<(index + 4)].joined(separator: " "), default: 0] += 1
        }
        guard (counts.values.max() ?? 0) >= 6 else { return 0 }
        let repeated = counts.values.filter { $0 >= 3 }.reduce(0) { $0 + $1 - 2 }
        let ratio = Double(repeated) / Double(words.count - 3)
        return ratio >= 0.3 ? ratio : 0
    }

    public static func prefers(_ candidate: String, over original: String) -> Bool {
        guard tokens(candidate).count >= 5 else { return false }
        let originalScore = score(original)
        return originalScore > 0 && score(candidate) <= originalScore - 0.15
    }

    /// Words taken by a phrase repeated back to back beyond its first occurrence, counting only runs that look like
    /// a decoder loop: 3+ words said 3 times, 2 words 4 times or 1 word 5 times. Short dictation never reaches `score`.
    public static func loopedWords(_ text: String) -> Int {
        let words = tokens(text)
        var worst = 0
        for size in 1...8 where words.count >= size * 3 {
            let needed = size >= 3 ? 3 : size == 2 ? 4 : 5
            var start = 0
            while start + size <= words.count {
                var count = 1
                while start + (count + 1) * size <= words.count,
                      words[(start + count * size)..<(start + (count + 1) * size)] == words[start..<(start + size)] { count += 1 }
                if count >= needed { worst = max(worst, (count - 1) * size) }
                start += 1
            }
        }
        return worst
    }

    public static func dictationLoops(_ text: String) -> Bool { score(text) > 0 || loopedWords(text) > 0 }

    /// A dictation retry wins only when it repeats less and keeps most of the words that were not part of the loop.
    public static func dictationPrefers(_ candidate: String, over original: String) -> Bool {
        let originalLoop = loopedWords(original), candidateLoop = loopedWords(candidate)
        guard dictationLoops(original), candidateLoop < originalLoop || score(candidate) < score(original) else { return false }
        guard candidateLoop <= originalLoop, score(candidate) <= score(original) else { return false }
        let kept = max(1, tokens(original).count - originalLoop)
        return Double(tokens(candidate).count) >= Double(kept) * 0.7
    }

    private static func tokens(_ text: String) -> [String] {
        text.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)
    }
}
