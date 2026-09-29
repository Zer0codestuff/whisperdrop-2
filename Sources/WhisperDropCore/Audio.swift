import Foundation

/// Contract file. Signatures are fixed; bodies are implemented by the core worker.

/// 16 kHz mono Float samples in -1...1 are used everywhere.
public let whisperSampleRate = 16_000

public enum SpeechDetector {
    /// Root mean square level of a buffer, 0...1.
    public static func rms(_ samples: ArraySlice<Float>) -> Float { 0 }
    /// True when the buffer likely contains speech (energy based, robust to low constant noise).
    public static func hasSpeech(_ samples: [Float]) -> Bool { !samples.isEmpty }
    /// Removes leading and trailing silence, keeping `padding` seconds around speech.
    public static func trimSilence(_ samples: [Float], padding: Double = 0.2) -> [Float] { samples }
}

public struct AudioChunk: Sendable {
    /// Offset of the first sample from the start of the recording, in seconds.
    public var start: Double
    public var samples: [Float]
    public var hasSpeech: Bool
    public var duration: Double { Double(samples.count) / Double(whisperSampleRate) }
    public init(start: Double, samples: [Float], hasSpeech: Bool) {
        self.start = start; self.samples = samples; self.hasSpeech = hasSpeech
    }
}

/// Splits a continuous stream into chunks for Whisper, cutting at silences near `target` seconds and never exceeding `maxLength`.
public struct Chunker: Sendable {
    public let target: Double
    public let maxLength: Double
    public let minLength: Double
    public init(target: Double = 20, maxLength: Double = 28, minLength: Double = 1) {
        self.target = target; self.maxLength = maxLength; self.minLength = minLength
    }
    /// Feeds new samples and returns any chunks that are complete.
    public mutating func append(_ samples: [Float]) -> [AudioChunk] { [] }
    /// Returns the remaining buffered audio as a final chunk, if long enough.
    public mutating func flush() -> AudioChunk? { nil }
}

public enum WAVEncoder {
    /// 16-bit PCM little-endian mono WAV file bytes.
    public static func pcm16(_ samples: [Float], sampleRate: Int = whisperSampleRate) -> Data {
        var data = Data(capacity: 44 + samples.count * 2)
        func append<T: FixedWidthInteger>(_ value: T) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        let payload = UInt32(samples.count * 2)
        data.append(contentsOf: Array("RIFF".utf8)); append(36 + payload)
        data.append(contentsOf: Array("WAVEfmt ".utf8)); append(UInt32(16)); append(UInt16(1)); append(UInt16(1))
        append(UInt32(sampleRate)); append(UInt32(sampleRate * 2)); append(UInt16(2)); append(UInt16(16))
        data.append(contentsOf: Array("data".utf8)); append(payload)
        for sample in samples { append(Int16((max(-1, min(1, sample)) * 32767).rounded())) }
        return data
    }
}
