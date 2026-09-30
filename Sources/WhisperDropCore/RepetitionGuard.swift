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

    private static func tokens(_ text: String) -> [String] {
        text.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)
    }
}
