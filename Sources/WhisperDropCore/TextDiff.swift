import Foundation

public struct DiffPart: Equatable {
    public enum Kind { case unchanged, inserted, removed }
    public let text: String
    public let kind: Kind
}

public enum TextDiff {
    public static func parts(original: String, revised: String) -> [DiffPart] {
        // Include whitespace as tokens so punctuation and paragraph changes stay visible.
        let tokenize: (String) -> [String] = { value in
            let regex = try! NSRegularExpression(pattern: "\\s+|[\\p{L}\\p{N}_]+(?:['’][\\p{L}\\p{N}_]+)*|[^\\s\\p{L}\\p{N}_]")
            let ns = value as NSString
            return regex.matches(in: value, range: NSRange(location: 0, length: ns.length)).map { ns.substring(with: $0.range) }
        }
        let old = tokenize(original), new = tokenize(revised)
        let difference = new.difference(from: old)
        var removed = Set<Int>(), inserted = Set<Int>()
        for change in difference {
            switch change {
            case .remove(let i, _, _): removed.insert(i)
            case .insert(let i, _, _): inserted.insert(i)
            }
        }
        var result: [DiffPart] = [], i = 0, j = 0
        while i < old.count || j < new.count {
            if i < old.count && removed.contains(i) { result.append(.init(text: old[i], kind: .removed)); i += 1 }
            else if j < new.count && inserted.contains(j) { result.append(.init(text: new[j], kind: .inserted)); j += 1 }
            else if j < new.count { result.append(.init(text: new[j], kind: .unchanged)); i += 1; j += 1 }
            else { break }
        }
        return result
    }
}
