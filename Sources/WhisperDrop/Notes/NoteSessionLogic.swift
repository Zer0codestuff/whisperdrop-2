import Foundation
import WhisperDropCore

/// Which capture stream a chunk or line belongs to.
enum NoteStream: Equatable {
    case microphone
    case system
}

enum NoteCopy {
    static let microphoneDenied = "Microphone access is off. Turn it on in System Settings."
    static let noSpeech = "No speech was detected."
    static let systemAudioUnavailable = "System audio capture is not available on this Mac."
    static let couldNotCreateFolder = "Could not create a folder for this note."
    static let couldNotStart = "Could not start recording."
    static let partialTranscriptFile = "transcript.json"
    static let microphoneFile = "you.caf"
    static let systemFile = "others.caf"
    /// UserDefaults key set after the system tap has delivered non-silent audio.
    static let systemAudioConfirmedKey = "systemAudioConfirmed"
}

enum NoteCaptureError: LocalizedError {
    case unsupportedSystemAudio

    var errorDescription: String? {
        switch self {
        case .unsupportedSystemAudio: NoteCopy.systemAudioUnavailable
        }
    }
}

/// Language strings for whisper-server.
///
/// `whisper_lang_id` (`.runtime/src/whisper.cpp/src/whisper.cpp`) accepts the short code
/// (`g_lang` key, `"en"`) and the full English name (`"english"`). The compare is case-sensitive.
/// Settings and pinned requests use the short code, which is what the rest of the app stores.
enum NoteLanguage {
    @MainActor static func label(_ code: String) -> String {
        AppStore.languages.first { $0.0 == code }?.1 ?? code
    }
    static let entries: [(code: String, name: String)] = [
        ("en", "english"), ("zh", "chinese"), ("de", "german"), ("es", "spanish"),
        ("ru", "russian"), ("ko", "korean"), ("fr", "french"), ("ja", "japanese"),
        ("pt", "portuguese"), ("tr", "turkish"), ("pl", "polish"), ("ca", "catalan"),
        ("nl", "dutch"), ("ar", "arabic"), ("sv", "swedish"), ("it", "italian"),
        ("id", "indonesian"), ("hi", "hindi"), ("fi", "finnish"), ("vi", "vietnamese"),
        ("he", "hebrew"), ("uk", "ukrainian"), ("el", "greek"), ("ms", "malay"),
        ("cs", "czech"), ("ro", "romanian"), ("da", "danish"), ("hu", "hungarian"),
        ("ta", "tamil"), ("no", "norwegian"), ("th", "thai"), ("ur", "urdu"),
        ("hr", "croatian"), ("bg", "bulgarian"), ("lt", "lithuanian"), ("la", "latin"),
        ("mi", "maori"), ("ml", "malayalam"), ("cy", "welsh"), ("sk", "slovak"),
        ("te", "telugu"), ("fa", "persian"), ("lv", "latvian"), ("bn", "bengali"),
        ("sr", "serbian"), ("az", "azerbaijani"), ("sl", "slovenian"), ("kn", "kannada"),
        ("et", "estonian"), ("mk", "macedonian"), ("br", "breton"), ("eu", "basque"),
        ("is", "icelandic"), ("hy", "armenian"), ("ne", "nepali"), ("mn", "mongolian"),
        ("bs", "bosnian"), ("kk", "kazakh"), ("sq", "albanian"), ("sw", "swahili"),
        ("gl", "galician"), ("mr", "marathi"), ("pa", "punjabi"), ("si", "sinhala"),
        ("km", "khmer"), ("sn", "shona"), ("yo", "yoruba"), ("so", "somali"),
        ("af", "afrikaans"), ("oc", "occitan"), ("ka", "georgian"), ("be", "belarusian"),
        ("tg", "tajik"), ("sd", "sindhi"), ("gu", "gujarati"), ("am", "amharic"),
        ("yi", "yiddish"), ("lo", "lao"), ("uz", "uzbek"), ("fo", "faroese"),
        ("ht", "haitian creole"), ("ps", "pashto"), ("tk", "turkmen"), ("nn", "nynorsk"),
        ("mt", "maltese"), ("sa", "sanskrit"), ("lb", "luxembourgish"), ("my", "myanmar"),
        ("bo", "tibetan"), ("tl", "tagalog"), ("mg", "malagasy"), ("as", "assamese"),
        ("tt", "tatar"), ("haw", "hawaiian"), ("ln", "lingala"), ("ha", "hausa"),
        ("ba", "bashkir"), ("jw", "javanese"), ("su", "sundanese"), ("yue", "cantonese")
    ]

    static let codes: Set<String> = Set(entries.map(\.code))
    static let namesToCodes: [String: String] = Dictionary(uniqueKeysWithValues: entries.map { ($0.name, $0.code) })

    static func isAuto(_ setting: String) -> Bool {
        let trimmed = setting.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty || trimmed.lowercased() == "auto"
    }

    /// Short code for a user setting or a verbose_json language, or nil for auto, empty, and unknown names.
    static func whisperCode(for value: String) -> String? {
        let key = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if key.isEmpty || key == "auto" { return nil }
        if codes.contains(key) { return key }
        return namesToCodes[key]
    }

    /// Language form value for the next chunk. Auto stays `"auto"` until a detection is pinned.
    static func requestCode(setting: String, pinned: String?) -> String {
        if isAuto(setting) { return pinned ?? "auto" }
        let trimmed = setting.trimmingCharacters(in: .whitespacesAndNewlines)
        return whisperCode(for: trimmed) ?? trimmed.lowercased()
    }
}

enum NotePrompt {
    /// Last characters of accepted text sent as this stream's prompt. Under the 224-token prompt budget.
    static let tailLimit = 200
    /// Chunks shorter than this go out with no prompt. A short tail plus a long prompt makes whisper.cpp repeat.
    static let minimumDuration = 2.0

    static func tail(_ text: String, limit: Int = tailLimit) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard limit > 0, trimmed.count > limit else { return trimmed }
        let start = trimmed.index(trimmed.endIndex, offsetBy: -limit)
        return String(trimmed[start...])
    }

    /// `chunkDuration` is the chunk's sample length. The chunk contract has no separate speech-duration field.
    static func prompt(previousText: String, chunkDuration: Double, vocabulary: String = "") -> String? {
        guard chunkDuration >= minimumDuration else { return nil }
        let terms = vocabulary.trimmingCharacters(in: .whitespacesAndNewlines)
        let value = terms.isEmpty ? tail(previousText) : String(terms.prefix(400))
        if terms.isEmpty, RepetitionGuard.score(value) > 0 { return nil }
        return value.isEmpty ? nil : value
    }
}

/// Unconfirmed words heard since a stream's last confirmed chunk, shown after the transcript while recording.
struct NoteLivePreview: Equatable, Identifiable {
    var speaker: Speaker?
    var text: String
    var id: String { speaker?.rawValue ?? "all" }
}

enum NoteSpeakers {
    /// Labels exist only while both streams are actually recording. A mic-only lecture is not "You".
    static func label(stream: NoteStream, bothLive: Bool) -> Speaker? {
        guard bothLive else { return nil }
        return stream == .microphone ? .you : .others
    }
}

enum NoteAudio {
    static func savedFiles(in folder: URL) -> [URL] {
        let files = [NoteCopy.microphoneFile, NoteCopy.systemFile].map { folder.appendingPathComponent($0) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
        return files.isEmpty ? [folder] : files
    }
    /// Anything louder than this counts as non-silent when confirming the system tap. Exact zeros do not.
    static let audibleAmplitude: Float = 0.001

    static func containsAudibleSignal(_ samples: [Float]) -> Bool {
        samples.contains { $0.isFinite && abs($0) > audibleAmplitude }
    }
}

enum NoteClock {
    static func seconds(_ duration: Duration) -> Double {
        let parts = duration.components
        return Double(parts.seconds) + Double(parts.attoseconds) / 1e18
    }
}

struct NoteQueuedChunk {
    var sequence: Int
    var stream: NoteStream
    var chunk: AudioChunk
}

enum NoteQueue {
    /// Earliest capture time first. The sequence breaks ties so one stream stays in order.
    static func popNext(_ queue: inout [NoteQueuedChunk]) -> NoteQueuedChunk? {
        guard !queue.isEmpty else { return nil }
        var best = queue.startIndex
        var index = queue.index(after: best)
        while index < queue.endIndex {
            let candidate = queue[index]
            let current = queue[best]
            if candidate.chunk.start < current.chunk.start
                || (candidate.chunk.start == current.chunk.start && candidate.sequence < current.sequence) {
                best = index
            }
            index = queue.index(after: index)
        }
        return queue.remove(at: best)
    }
}

/// Per-source lines, prompt text, and the pinned language. Pure logic, no capture and no server.
struct NoteTranscriptState {
    var labelingSpeakers = false
    private(set) var pinnedLanguage: String?
    private var candidateLanguage: String?
    private var micCommittedEnd: Double?
    private var systemCommittedEnd: Double?
    private(set) var micText = ""
    private(set) var systemText = ""
    private(set) var micLines: [TranscriptSegment] = []
    private(set) var systemLines: [TranscriptSegment] = []

    func text(for stream: NoteStream) -> String {
        stream == .microphone ? micText : systemText
    }

    /// End of the last word committed from `stream`, in recording seconds.
    func committedEnd(for stream: NoteStream) -> Double? {
        stream == .microphone ? micCommittedEnd : systemCommittedEnd
    }

    func prompt(for stream: NoteStream, chunkDuration: Double) -> String? {
        NotePrompt.prompt(previousText: text(for: stream), chunkDuration: chunkDuration)
    }

    var segments: [TranscriptSegment] {
        if labelingSpeakers {
            return TranscriptMerger.merge(you: micLines, others: systemLines)
        }
        return NoteJobs.renumber(micLines + systemLines)
    }

    mutating func accept(_ result: ServerTranscription, stream: NoteStream, languageSetting: String,
                         chunk: AudioChunk? = nil) -> [TranscriptSegment] {
        let speaker = NoteSpeakers.label(stream: stream, bothLive: labelingSpeakers)
        let committed = stream == .microphone ? micCommittedEnd : systemCommittedEnd
        let cleaned = HallucinationFilter.clean(result.segments, removeNeighborRepeats: false, preserveShortClosings: true).compactMap { segment -> TranscriptSegment? in
            let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            var copy = segment
            copy.text = text
            copy.speaker = speaker
            if let stable = chunk?.stableUntil, let words = segment.words,
               words.map(\.text).joined().split(whereSeparator: \.isWhitespace).joined(separator: " ") == text {
                let selected = words.filter { word in
                    word.end <= stable && (committed == nil || word.end > committed!)
                }
                guard let first = selected.first, let last = selected.last else { return nil }
                copy.words = selected
                copy.text = selected.map(\.text).joined().trimmingCharacters(in: .whitespacesAndNewlines)
                copy.start = first.start
                copy.end = last.end
            } else if let committed, segment.end <= committed {
                return nil
            }
            return copy
        }
        if !cleaned.isEmpty, NoteLanguage.isAuto(languageSetting), pinnedLanguage == nil,
           let detected = result.language, let code = NoteLanguage.whisperCode(for: detected) {
            if candidateLanguage == code { pinnedLanguage = code }
            else { candidateLanguage = code }
        }
        if let end = cleaned.last?.end {
            if stream == .microphone { micCommittedEnd = end }
            else { systemCommittedEnd = end }
        }
        let addition = cleaned.map(\.text).joined(separator: " ")
        if addition.isEmpty {
            // The filter dropped the chunk. Drop this stream's prompt so the next request cannot repeat it.
            setText("", for: stream)
        } else {
            let prior = text(for: stream)
            setText(prior.isEmpty ? addition : prior + " " + addition, for: stream)
        }
        switch stream {
        case .microphone: micLines.append(contentsOf: cleaned)
        case .system: systemLines.append(contentsOf: cleaned)
        }
        return segments
    }

    private mutating func setText(_ value: String, for stream: NoteStream) {
        if stream == .microphone { micText = value } else { systemText = value }
    }
}

enum NoteJobs {
    static func fallbackTitle(at date: Date, timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "MMM d, yyyy, h:mm a"
        return "Note \(formatter.string(from: date))"
    }

    static func resolvedTitle(_ custom: String, at date: Date, timeZone: TimeZone = .current) -> String {
        let trimmed = custom.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? fallbackTitle(at: date, timeZone: timeZone) : trimmed
    }

    static func renumber(_ segments: [TranscriptSegment]) -> [TranscriptSegment] {
        let ordered = segments.sorted { lhs, rhs in
            if lhs.start != rhs.start { return lhs.start < rhs.start }
            return lhs.id < rhs.id
        }
        return ordered.enumerated().map { index, segment in
            var copy = segment
            copy.id = index
            return copy
        }
    }

    static func make(
        folder: URL,
        transcriptFolder: URL? = nil,
        customTitle: String,
        recordedAt: Date,
        segments: [TranscriptSegment],
        modelName: String,
        duration: Double,
        keepAudio: Bool,
        detectedSpeech: Bool,
        transcriptionWarning: String?,
        timeZone: TimeZone = .current
    ) -> TranscriptionJob {
        var job = TranscriptionJob(source: transcriptFolder ?? folder, title: resolvedTitle(customTitle, at: recordedAt, timeZone: timeZone))
        job.kind = .note
        job.status = .completed
        job.created = recordedAt
        job.segments = segments
        job.transcript = TranscriptOutput.labeledText(segments)
        job.modelName = modelName
        job.duration = duration
        job.audioFile = keepAudio ? folder : nil
        job.error = transcriptionWarning
        if segments.isEmpty {
            job.error = detectedSpeech ? (transcriptionWarning ?? NoteCopy.noSpeech) : NoteCopy.noSpeech
        }
        return job
    }
}
