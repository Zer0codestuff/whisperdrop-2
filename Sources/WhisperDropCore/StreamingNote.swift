import Foundation

/// Recorded audio a streaming note can still decode. Samples before the earliest possible window are dropped,
/// so memory stays bounded however long the note runs. Times are in seconds from the start of the recording.
public struct RollingAudio: Sendable {
    /// Frame level that counts as speech. The lecture chunker uses the same values.
    public var speechRMS: Float = 0.004
    public var minimumSpeech = 0.1
    private var samples: [Float] = []
    private var firstSample = 0

    public init() {}

    /// Recording time of the oldest retained sample.
    public var start: Double { Double(firstSample) / Double(whisperSampleRate) }
    /// Recording time of the newest sample.
    public var end: Double { Double(firstSample + samples.count) / Double(whisperSampleRate) }

    public mutating func append(_ new: [Float]) {
        samples.append(contentsOf: new)
    }

    /// Retained audio inside `range`, or nil when none is left.
    public func audio(_ range: Range<Double>) -> AudioChunk? {
        let rate = Double(whisperSampleRate)
        let from = max(0, min(samples.count, Int((range.lowerBound * rate).rounded()) - firstSample))
        let to = max(from, min(samples.count, Int((range.upperBound * rate).rounded()) - firstSample))
        guard to > from else { return nil }
        let slice = Array(samples[from..<to])
        return AudioChunk(start: Double(firstSample + from) / rate, samples: slice,
                          hasSpeech: Self.speechSeconds(slice, threshold: speechRMS) >= minimumSpeech)
    }

    /// Drops audio before `time`.
    public mutating func discard(before time: Double) {
        let count = min(samples.count, Int((time * Double(whisperSampleRate)).rounded(.down)) - firstSample)
        guard count > 0 else { return }
        samples.removeFirst(count)
        firstSample += count
    }

    static func speechSeconds(_ samples: [Float], threshold: Float) -> Double {
        let frame = 320
        var frames = 0
        var index = 0
        while index + frame <= samples.count {
            var sum: Float = 0
            for sample in samples[index..<(index + frame)] { sum += sample * sample }
            if (sum / Float(frame)).squareRoot() >= threshold { frames += 1 }
            index += frame
        }
        return Double(frames * frame) / Double(whisperSampleRate)
    }
}

/// Settled words grouped into sentences, one reading paragraph each. The last sentence stays open until a word
/// ends with `.`, `!` or `?`; there is no time limit.
public struct SentenceParagraphs: Sendable {
    public var speaker: Speaker?
    public private(set) var closed: [TranscriptSegment] = []
    public private(set) var open: [TranscriptWord] = []

    public init(speaker: Speaker? = nil) {
        self.speaker = speaker
    }

    public mutating func append(_ words: [TranscriptWord]) {
        for word in words where !word.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            open.append(word)
            if TranscriptOutput.endsSentence(word.text), let sentence = segment(open) {
                closed.append(sentence)
                open = []
            }
        }
    }

    /// Closed sentences, then the open one.
    public var segments: [TranscriptSegment] {
        guard let current = segment(open) else { return closed }
        return closed + [current]
    }

    private func segment(_ words: [TranscriptWord]) -> TranscriptSegment? {
        let text = LiveText.join(words)
        guard let first = words.first, let last = words.last, !text.isEmpty else { return nil }
        return TranscriptSegment(id: 0, start: first.start, end: last.end, text: text, speaker: speaker, words: words)
    }
}

public extension TranscriptionModel {
    /// Whisper models are kept as legacy models for languages Parakeet does not cover and for vocabulary hints.
    var isLegacy: Bool { engine == .whisper }

    /// Whisper models tried, in order, when the chosen model does not transcribe a language.
    static let legacyFallbackOrder = ["turbo", "turbo-q8", "medium", "small", "base", "tiny"]

    /// `chosen`, or the first installed legacy model that transcribes `language` when `chosen` does not.
    static func resolved(_ chosen: Self, language: String, installed: Set<String>) -> Self {
        guard !chosen.supports(language: language) else { return chosen }
        for id in legacyFallbackOrder where installed.contains(id) {
            if let model = catalog.first(where: { $0.id == id }), model.supports(language: language) { return model }
        }
        return chosen
    }
}
