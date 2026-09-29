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
        struct Output: Decodable {
            struct Segment: Decodable { let start: Double; let end: Double; let text: String }
            let language: String?
            let text: String?
            let segments: [Segment]?
        }
        let output = try JSONDecoder().decode(Output.self, from: data)
        let raw = output.segments ?? output.text.map { [Output.Segment(start: 0, end: 0, text: $0)] } ?? []
        let segments = raw.enumerated().map { index, value in
            TranscriptSegment(id: index, start: value.start + offset, end: value.end + offset,
                              text: value.text.trimmingCharacters(in: .whitespacesAndNewlines), speaker: speaker)
        }.filter { !$0.text.isEmpty }
        return ServerTranscription(segments: segments, language: output.language)
    }
    /// Plain text; when segments carry speakers, consecutive lines by the same speaker are grouped under "You:" / "Others:" labels.
    static func labeledText(_ segments: [TranscriptSegment]) -> String {
        let rows = segments.filter {
            !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        guard rows.contains(where: { $0.speaker != nil }) else {
            return rows.map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }.joined(separator: "\n")
        }
        var paragraphs: [String] = []
        var index = 0
        while index < rows.count {
            let speaker = rows[index].speaker
            var end = index + 1
            while end < rows.count, rows[end].speaker == speaker { end += 1 }
            let body = rows[index..<end]
                .map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }
                .joined(separator: " ")
            if let speaker {
                paragraphs.append("\(speaker.label): \(body)")
            } else {
                paragraphs.append(body)
            }
            index = end
        }
        return paragraphs.joined(separator: "\n\n")
    }
}

public enum HallucinationFilter {
    /// Removes known silence hallucinations, empty and bracketed non-speech segments, and runs of repeated text.
    public static func clean(_ segments: [TranscriptSegment]) -> [TranscriptSegment] {
        var kept: [TranscriptSegment] = []
        for segment in segments {
            guard let text = cleanedText(segment.text) else { continue }
            if let previous = kept.last,
               neighborRepeat(previous.text, text) {
                continue
            }
            var copy = segment
            copy.text = text
            kept.append(copy)
        }
        return kept
    }

    /// Cleans dictation output into one line of text ready to insert. Returns nil when nothing meaningful was said.
    ///
    /// Dictation audio is already speech-gated before it reaches Whisper, so a real "Thank you." or "Grazie."
    /// is kept. Only bracketed non-speech tags and subtitle credit lines are dropped here.
    public static func dictationText(_ transcription: ServerTranscription) -> String? {
        let kept = transcription.segments.compactMap { segment -> String? in
            let text = collapseWhitespace(removingNonSpeechAnnotations(segment.text))
            let key = normalizedTranscript(text)
            guard !key.isEmpty else { return nil }
            if key.count <= 160, dictationCreditMarkers.contains(where: { key.contains($0) }) { return nil }
            return text
        }
        let line = collapseWhitespace(kept.joined(separator: " "))
        return line.isEmpty ? nil : line
    }

    private static func cleanedText(_ raw: String) -> String? {
        let text = collapseWhitespace(removingNonSpeechAnnotations(raw))
        guard !text.isEmpty else { return nil }
        let key = normalizedTranscript(text)
        guard !key.isEmpty else { return nil }
        if matchesExact(key) || containsCredit(key) || isLooped(key) { return nil }
        return text
    }

    private static func neighborRepeat(_ previous: String, _ next: String) -> Bool {
        let left = normalizedTranscript(previous)
        let right = normalizedTranscript(next)
        guard !left.isEmpty, !right.isEmpty else { return false }
        return TranscriptMerger.similarity(left, right) >= 0.90
    }

    private static func containsCredit(_ key: String) -> Bool {
        key.count <= 160 && creditMarkers.contains { key.contains($0) }
    }

    /// Whole line is one denylist phrase, or that phrase repeated.
    private static func matchesExact(_ key: String) -> Bool {
        guard !key.isEmpty else { return false }
        for phrase in exactPhrases {
            var rest = key
            var count = 0
            while !rest.isEmpty {
                if rest.hasPrefix(phrase) {
                    count += 1
                    rest.removeFirst(phrase.count)
                    if rest.hasPrefix(" ") {
                        rest.removeFirst()
                    } else if !rest.isEmpty {
                        break
                    }
                } else {
                    break
                }
            }
            if rest.isEmpty, count >= 1 { return true }
        }
        return false
    }

    /// A token unit repeated at least three times, and at least six tokens long.
    private static func isLooped(_ key: String) -> Bool {
        let tokens = key.split(separator: " ").map(String.init)
        let count = tokens.count
        guard count >= 6 else { return false }
        for unit in 1...(count / 3) {
            guard count % unit == 0, count / unit >= 3 else { continue }
            var same = true
            for index in unit..<count where tokens[index] != tokens[index % unit] {
                same = false
                break
            }
            if same { return true }
        }
        return false
    }

    private static func removingNonSpeechAnnotations(_ text: String) -> String {
        var output: [Character] = []
        var index = text.startIndex
        while index < text.endIndex {
            let character = text[index]
            if character == "[" || character == "(" {
                let closing: Character = character == "[" ? "]" : ")"
                var cursor = text.index(after: index)
                var found: String.Index?
                while cursor < text.endIndex {
                    if text[cursor] == closing {
                        found = cursor
                        break
                    }
                    cursor = text.index(after: cursor)
                }
                if let found {
                    let inner = text[text.index(after: index)..<found]
                    if isNonSpeechAnnotation(inner) {
                        if output.last?.isWhitespace == false { output.append(" ") }
                        index = text.index(after: found)
                        continue
                    }
                }
            }
            output.append(character)
            index = text.index(after: index)
        }
        return String(output)
    }

    private static func isNonSpeechAnnotation(_ inner: Substring) -> Bool {
        let key = normalizedTranscript(String(inner))
        if key.isEmpty || annotationPhrases.contains(key) { return true }
        let words = key.split(separator: " ")
        guard !words.isEmpty else { return true }
        return words.allSatisfy { annotationWords.contains(String($0)) }
    }

    private static let exactPhrases: [String] = [
        "Thank you.",
        "Thank you for watching.",
        "Thanks for watching.",
        "Thanks for listening.",
        "Please subscribe.",
        "Subtitles by.",
        "Subtitles by the Amara.org community.",
        "Grazie per la visione.",
        "Grazie per aver guardato.",
        "Sottotitoli a cura di.",
        "Sous-titres réalisés par la communauté d'Amara.org.",
        "Merci d'avoir regardé.",
        "Subtítulos realizados por la comunidad de Amara.org.",
        "Gracias por ver.",
        "Vielen Dank fürs Zuschauen.",
        "Untertitel im Auftrag des ZDF.",
        "Obrigado por assistir.",
        "Legendas pela comunidade de Amara.org.",
        "Спасибо за просмотр.",
        "ご視聴ありがとうございました",
        "ご視聴ありがとうございます",
        "시청해 주셔서 감사합니다",
        "谢谢观看",
        "謝謝觀看",
        "Bedankt voor het kijken.",
        "Dzięki za oglądanie.",
        "İzlediğiniz için teşekkürler.",
        "شكرا للمشاهدة",
    ].map(normalizedTranscript)

    private static let creditMarkers: [String] = [
        "amara org",
        "sottotitoli",
        "sous titres",
        "subtitulos realizados",
        "grazie per la visione",
        "grazie per aver guardato",
        "thanks for watching",
        "thank you for watching",
        "please subscribe",
    ].map(normalizedTranscript)

    /// Subtitle credit lines that never come from someone dictating.
    private static let dictationCreditMarkers: [String] = [
        "amara org",
        "subtitles by",
        "sottotitoli a cura",
        "sottotitoli creati",
        "sous titres realises",
        "sous titres réalisés",
        "subtitulos realizados",
        "subtítulos realizados",
        "untertitel im auftrag",
        "legendas pela",
    ].map(normalizedTranscript)

    private static let annotationPhrases: Set<String> = [
        "music", "applause", "laughter", "silence", "blank audio", "inaudible",
        "background noise", "background music", "music playing", "upbeat music",
        "dramatic music", "foreign language", "speaking in foreign language",
        "speaking foreign language", "indistinct chatter", "crosstalk",
        "phone ringing", "keyboard clicking",
    ]

    private static let annotationWords: Set<String> = [
        "music", "musical", "applause", "laughter", "laugh", "laughs", "laughing",
        "silence", "silent", "blank", "audio", "inaudible", "cough", "coughing",
        "noise", "background", "cheering", "cheers", "sigh", "sighing", "playing",
        "upbeat", "dramatic", "clapping", "sneeze", "beep", "beeping", "snoring",
        "gasp", "crying", "whispering", "unintelligible", "static", "loud", "soft",
        "wild", "gentle", "faint", "distant",
    ]
}

public enum TranscriptMerger {
    /// Merges both speakers by start time and renumbers ids. Drops "You" segments that overlap and closely match an "Others" segment (speaker echo).
    public static func merge(you: [TranscriptSegment], others: [TranscriptSegment]) -> [TranscriptSegment] {
        let keptYou = you.filter { segment in
            !others.contains { isEcho(segment, $0) }
        }
        let ordered = (keptYou + others).sorted { lhs, rhs in
            if lhs.start != rhs.start { return lhs.start < rhs.start }
            let leftOthers = lhs.speaker == .others
            let rightOthers = rhs.speaker == .others
            if leftOthers != rightOthers { return leftOthers }
            if lhs.end != rhs.end { return lhs.end < rhs.end }
            return lhs.id < rhs.id
        }
        return ordered.enumerated().map { index, segment in
            var copy = segment
            copy.id = index
            return copy
        }
    }

    /// Normalized similarity of two texts, 0...1.
    public static func similarity(_ a: String, _ b: String) -> Double {
        similarityOfNormalized(normalizedTranscript(a), normalizedTranscript(b))
    }

    private static func isEcho(_ you: TranscriptSegment, _ others: TranscriptSegment) -> Bool {
        guard overlaps(you, others, pad: 1) else { return false }
        let yours = normalizedTranscript(you.text)
        let theirs = normalizedTranscript(others.text)
        guard yours.count >= 8, theirs.count >= 8 else { return false }
        if similarityOfNormalized(yours, theirs) >= 0.84 { return true }
        let short = yours.count <= theirs.count ? yours : theirs
        let long = yours.count <= theirs.count ? theirs : yours
        return short.count >= 24 && long.contains(short)
    }

    private static func overlaps(_ lhs: TranscriptSegment, _ rhs: TranscriptSegment, pad: Double) -> Bool {
        lhs.start < rhs.end + pad && rhs.start < lhs.end + pad
    }
}

/// Letters and numbers only, lowercased, so "Amara.org" and "amara org" meet.
private func normalizedTranscript(_ text: String) -> String {
    var characters: [Character] = []
    characters.reserveCapacity(text.count)
    var pendingSpace = false
    for character in text.lowercased() {
        if character.isLetter || character.isNumber {
            if pendingSpace, !characters.isEmpty { characters.append(" ") }
            pendingSpace = false
            characters.append(character)
        } else if !characters.isEmpty {
            pendingSpace = true
        }
    }
    return String(characters)
}

private func collapseWhitespace(_ text: String) -> String {
    var characters: [Character] = []
    characters.reserveCapacity(text.count)
    var pendingSpace = false
    for character in text {
        if character.isWhitespace || character.isNewline {
            if !characters.isEmpty { pendingSpace = true }
        } else {
            if pendingSpace {
                characters.append(" ")
                pendingSpace = false
            }
            characters.append(character)
        }
    }
    return String(characters)
}

/// `1 - levenshtein / max(count)` on strings already normalized. Sides longer than 400 characters score 0.
private func similarityOfNormalized(_ lhs: String, _ rhs: String) -> Double {
    if lhs.isEmpty && rhs.isEmpty { return 1 }
    if lhs.count > 400 || rhs.count > 400 { return 0 }
    let left = Array(lhs)
    let right = Array(rhs)
    let denominator = max(left.count, right.count)
    guard denominator > 0 else { return 1 }
    return 1 - Double(levenshtein(left, right)) / Double(denominator)
}

private func levenshtein(_ lhs: [Character], _ rhs: [Character]) -> Int {
    let rowCount = lhs.count
    let columnCount = rhs.count
    if rowCount == 0 { return columnCount }
    if columnCount == 0 { return rowCount }
    var previous = Array(0...columnCount)
    var current = Array(repeating: 0, count: columnCount + 1)
    for row in 1...rowCount {
        current[0] = row
        for column in 1...columnCount {
            let cost = lhs[row - 1] == rhs[column - 1] ? 0 : 1
            current[column] = min(previous[column] + 1, current[column - 1] + 1, previous[column - 1] + cost)
        }
        swap(&previous, &current)
    }
    return previous[columnCount]
}
