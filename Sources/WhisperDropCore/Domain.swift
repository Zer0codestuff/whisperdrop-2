import Foundation

public struct TranscriptionModel: Identifiable, Sendable, Equatable {
    public let id: String
    public let name: String
    public let detail: String
    public let filename: String
    public let bytes: Int64
    public let sha256: String
    public var url: URL { URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/\(filename)")! }
    public var size: String { ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) }
    public static let catalog: [Self] = [
        .init(id: "tiny", name: "Tiny", detail: "Smallest download. For clear, simple speech.", filename: "ggml-tiny-q5_1.bin", bytes: 32152673, sha256: "818710568da3ca15689e31a743197b520007872ff9576237bda97bd1b469c3d7"),
        .init(id: "base", name: "Base", detail: "Lightweight for everyday recordings.", filename: "ggml-base-q5_1.bin", bytes: 59707625, sha256: "422f1ae452ade6f30a004d7e5c6a43195e4433bc370bf23fac9cc591f01a8898"),
        .init(id: "small", name: "Small", detail: "More detail, with a modest memory footprint.", filename: "ggml-small-q5_1.bin", bytes: 190085487, sha256: "ae85e4a935d7a567bd102fe55afc16bb595bdb618e11b2fc7591bc08120411bb"),
        .init(id: "medium", name: "Medium", detail: "For difficult recordings. Slower than Turbo.", filename: "ggml-medium-q5_0.bin", bytes: 539212467, sha256: "19fea4b380c3a618ec4723c3eef2eb785ffba0d0538cf43f8f235e7b3b34220f"),
        .init(id: "turbo", name: "Turbo", detail: "Recommended balance of speed and accuracy.", filename: "ggml-large-v3-turbo-q5_0.bin", bytes: 574041195, sha256: "394221709cd5ad1f40c46e6031ca61bce88931e6e088c188294c6d5a55ffa7e2"),
        .init(id: "turbo-q8", name: "Turbo Q8", detail: "Higher precision, with a larger download.", filename: "ggml-large-v3-turbo-q8_0.bin", bytes: 874188075, sha256: "317eb69c11673c9de1e1f0d459b253999804ec71ac4c23c17ecf5fbe24e259a1")
    ]
}

public enum Speaker: String, Codable, Sendable, CaseIterable {
    case you, others
    public var label: String { self == .you ? "You" : "Others" }
}

public enum JobKind: String, Codable, Sendable {
    case file, youtube, note
}

/// How long the resident model stays in memory after its last use.
public enum ModelResidency: String, Codable, Sendable, CaseIterable, Identifiable {
    case afterUse, twoMinutes, tenMinutes, thirtyMinutes, oneHour, always
    public var id: String { rawValue }
    /// Seconds of inactivity before unloading. `nil` keeps the model loaded while the app runs.
    public var idleSeconds: Double? {
        switch self {
        case .afterUse: 0
        case .twoMinutes: 120
        case .tenMinutes: 600
        case .thirtyMinutes: 1800
        case .oneHour: 3600
        case .always: nil
        }
    }
    public var label: String {
        switch self {
        case .afterUse: "Unload after each use"
        case .twoMinutes: "After 2 minutes idle"
        case .tenMinutes: "After 10 minutes idle"
        case .thirtyMinutes: "After 30 minutes idle"
        case .oneHour: "After 1 hour idle"
        case .always: "Keep loaded while the app runs"
        }
    }
}

public enum JobStatus: String, Codable, Sendable {
    case queued, downloading, converting, transcribing, completed, failed, cancelled
    public var label: String { rawValue.capitalized }
    public var isActive: Bool { [.downloading, .converting, .transcribing].contains(self) }
}

public struct TranscriptSegment: Identifiable, Codable, Sendable {
    public var id: Int
    public var start: Double
    public var end: Double
    public var text: String
    public var speaker: Speaker?
    public init(id: Int, start: Double, end: Double, text: String, speaker: Speaker? = nil) {
        self.id = id; self.start = start; self.end = end; self.text = text; self.speaker = speaker
    }
    /// `mm:ss`, or `h:mm:ss` from one hour on.
    public var timeLabel: String {
        let total = max(0, Int(start))
        if total >= 3600 { return String(format: "%d:%02d:%02d", total / 3600, (total / 60) % 60, total % 60) }
        return String(format: "%02d:%02d", total / 60, total % 60)
    }
}

public struct TranscriptionJob: Identifiable, Codable, Sendable {
    public var id: UUID
    public var source: URL
    public var title: String
    public var isRemote: Bool
    public var status: JobStatus
    public var created: Date
    public var transcript: String
    public var segments: [TranscriptSegment]
    public var error: String?
    public var modelName: String?
    public var duration: Double?
    /// `nil` in libraries saved before notes existed; use `resolvedKind`.
    public var kind: JobKind?
    /// Recorded audio kept for notes, if the user chose to keep it.
    public var audioFile: URL?
    public var resolvedKind: JobKind { kind ?? (isRemote ? .youtube : .file) }
    public init(source: URL, title: String? = nil, isRemote: Bool = false) {
        id = UUID(); self.source = source
        self.title = title ?? source.deletingPathExtension().lastPathComponent
        self.isRemote = isRemote; status = .queued; created = Date()
        transcript = ""; segments = []
    }
}

public enum MediaInput {
    public static let extensions: Set<String> = ["mp3", "wav", "m4a", "ogg", "flac", "opus", "webm", "mp4", "aac", "aiff", "aif", "mov", "mkv", "wma", "m4v"]
    public static func youtubeURL(_ text: String) -> URL? {
        guard let url = URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines)),
              ["https", "http"].contains(url.scheme?.lowercased() ?? ""),
              let host = url.host?.lowercased(),
              ["youtube.com", "www.youtube.com", "m.youtube.com", "music.youtube.com", "youtu.be"].contains(host),
              url.user == nil, url.password == nil else { return nil }
        return url
    }
}

public enum TranscriptOutput {
    public static func parseWhisper(_ data: Data) throws -> [TranscriptSegment] {
        struct Output: Decodable {
            struct Segment: Decodable {
                struct Offset: Decodable { let from: Double; let to: Double }
                let offsets: Offset
                let text: String
            }
            let transcription: [Segment]
        }
        return try JSONDecoder().decode(Output.self, from: data).transcription.enumerated().map { index, value in
            TranscriptSegment(id: index, start: value.offsets.from / 1000, end: value.offsets.to / 1000,
                              text: value.text.trimmingCharacters(in: .whitespacesAndNewlines))
        }.filter { !$0.text.isEmpty }
    }
    public static func subtitles(_ segments: [TranscriptSegment], vtt: Bool) -> String {
        func stamp(_ seconds: Double) -> String {
            let ms = max(0, Int((seconds * 1000).rounded()))
            return String(format: "%02d:%02d:%02d%@%03d", ms / 3600000, (ms / 60000) % 60, (ms / 1000) % 60, vtt ? "." : ",", ms % 1000)
        }
        return (vtt ? "WEBVTT\n\n" : "") + segments.enumerated().map { i, s in
            "\(i + 1)\n\(stamp(s.start)) --> \(stamp(s.end))\n\(s.text)\n"
        }.joined(separator: "\n")
    }
}
