import Foundation

public extension TranscriptOutput {
    /// A heading, a details line and one reading paragraph per line, each with its time and speaker.
    static func markdown(_ job: TranscriptionJob) -> String {
        var lines = ["# \(job.title)", ""]
        let details = [job.modelName, job.duration.map(durationLabel)].compactMap { $0 }
        if !details.isEmpty { lines += ["*" + details.joined(separator: " · ") + "*", ""] }
        for paragraph in paragraphs(job.segments, eachSentence: job.sentenceParagraphs == true) {
            let speaker = paragraph.speaker.map { "**\($0.label)** " } ?? ""
            lines += ["`\(paragraph.timeLabel)` \(speaker)\(paragraph.text.trimmingCharacters(in: .whitespacesAndNewlines))", ""]
        }
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
    }

    /// Title, details, plain text and every segment with its word timings.
    static func json(_ job: TranscriptionJob) throws -> String {
        struct Export: Encodable {
            let title: String
            let model: String?
            let duration: Double?
            let created: Date
            let text: String
            let segments: [TranscriptSegment]
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        let export = Export(title: job.title, model: job.modelName, duration: job.duration, created: job.created,
                            text: labeledText(job.segments, eachSentence: job.sentenceParagraphs == true), segments: job.segments)
        return String(decoding: try encoder.encode(export), as: UTF8.self) + "\n"
    }

    /// "42 s", "3 min 7 s", "1 h 05 min".
    static func durationLabel(_ seconds: Double) -> String {
        let total = max(0, Int(seconds.rounded()))
        if total < 60 { return "\(total) s" }
        if total < 600 { return total % 60 == 0 ? "\(total / 60) min" : "\(total / 60) min \(total % 60) s" }
        if total < 3600 { return "\(total / 60) min" }
        return String(format: "%d h %02d min", total / 3600, (total / 60) % 60)
    }
}

/// Case- and accent-insensitive search, so "perche" finds "perché".
public enum TranscriptSearch {
    public static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
    }

    /// Ranges in `text` where `query` occurs, ignoring case and accents.
    public static func ranges(of query: String, in text: String) -> [Range<String.Index>] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return [] }
        var found: [Range<String.Index>] = []
        var start = text.startIndex
        while start < text.endIndex,
              let range = text.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], range: start..<text.endIndex) {
            found.append(range)
            start = range.upperBound
        }
        return found
    }

    /// True when every word of `query` appears in the title or the transcript.
    public static func matches(_ job: TranscriptionJob, _ query: String) -> Bool {
        let terms = fold(query).split(whereSeparator: \.isWhitespace)
        guard !terms.isEmpty else { return true }
        let haystack = fold(job.title + "\n" + (job.transcript.isEmpty ? job.segments.map(\.text).joined(separator: " ") : job.transcript))
        return terms.allSatisfy { haystack.contains($0) }
    }
}

/// Date sections of the library sidebar: Today, Yesterday, Previous 7 days, Previous 30 days, then months.
public enum LibrarySections {
    public struct Section: Identifiable, Sendable {
        public let title: String
        public let jobs: [TranscriptionJob]
        public var id: String { title }
    }

    public static func title(for date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        let today = calendar.startOfDay(for: now)
        let day = calendar.startOfDay(for: date)
        let days = calendar.dateComponents([.day], from: day, to: today).day ?? 0
        switch days {
        case ..<1: return "Today"
        case 1: return "Yesterday"
        case 2...6: return "Previous 7 days"
        case 7...29: return "Previous 30 days"
        default:
            let formatter = DateFormatter()
            formatter.calendar = calendar
            formatter.timeZone = calendar.timeZone
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "MMMM yyyy"
            return formatter.string(from: date)
        }
    }

    /// Keeps the library order and starts a section whenever the title changes.
    public static func sections(_ jobs: [TranscriptionJob], now: Date = Date(), calendar: Calendar = .current) -> [Section] {
        var result: [(String, [TranscriptionJob])] = []
        for job in jobs {
            let title = title(for: job.created, now: now, calendar: calendar)
            if let index = result.firstIndex(where: { $0.0 == title }) { result[index].1.append(job) }
            else { result.append((title, [job])) }
        }
        return result.map { Section(title: $0.0, jobs: $0.1) }
    }
}
