import Foundation

/// Pause-aligned windows for models graded on short utterances, such as Parakeet TDT.
/// Audio up to `singleShot` seconds stays whole. Longer audio is cut inside each 25 to 35 second band,
/// in the middle of its longest quiet run of 50 ms blocks, or at 30 seconds when the band never pauses.
public enum LongAudioPlan {
    public static let singleShot = 35.0
    public static let bandStart = 25.0
    public static let bandEnd = 35.0
    public static let target = 30.0
    public static let blockSize = 800
    static let noiseFloor: Float = 0.004
    static let gateRatio: Float = 0.18

    /// RMS of each 50 ms block. The last block is zero padded.
    public static func blockRMS(_ samples: ArraySlice<Float>) -> [Float] {
        var values: [Float] = []
        values.reserveCapacity(samples.count / blockSize + 1)
        var index = samples.startIndex
        while index < samples.endIndex {
            let end = min(samples.endIndex, index + blockSize)
            var sum: Float = 0
            for i in index..<end { sum += samples[i] * samples[i] }
            values.append((sum / Float(blockSize)).squareRoot())
            index = end
        }
        return values
    }

    public static func windows(_ samples: [Float]) -> [Range<Int>] {
        windows(blockRMS: blockRMS(samples[...]), sampleCount: samples.count)
    }

    /// Contiguous windows that cover `0..<sampleCount`.
    public static func windows(blockRMS rms: [Float], sampleCount: Int, sampleRate: Int = whisperSampleRate) -> [Range<Int>] {
        let single = Int(singleShot * Double(sampleRate))
        guard sampleCount > single else { return sampleCount > 0 ? [0..<sampleCount] : [] }
        var result: [Range<Int>] = []
        var start = 0
        while sampleCount - start > single {
            let low = start + Int(bandStart * Double(sampleRate))
            let high = start + Int(bandEnd * Double(sampleRate))
            let goal = start + Int(target * Double(sampleRate))
            let first = (low + blockSize - 1) / blockSize
            let last = min(rms.count, high / blockSize)
            let peak = rms[min(rms.count, start / blockSize)..<last].max() ?? 0
            let gate = max(noiseFloor, gateRatio * peak)
            var cut = goal
            var best: (length: Int, distance: Int)?
            var block = first
            while block < last {
                guard rms[block] <= gate else { block += 1; continue }
                var end = block
                while end < last, rms[end] <= gate { end += 1 }
                let middle = (block + end) * blockSize / 2
                let candidate = (length: end - block, distance: -abs(middle - goal))
                // Longest quiet run wins; ties go to the run nearest the target.
                if best.map({ candidate.length > $0.length || (candidate.length == $0.length && candidate.distance > $0.distance) }) ?? true {
                    best = candidate
                    cut = middle
                }
                block = end
            }
            cut = max(low, min(high, cut, sampleCount))
            result.append(start..<cut)
            start = cut
        }
        result.append(start..<sampleCount)
        return result
    }
}

public enum WAVDecoder {
    /// Mono float samples from 16-bit PCM WAV bytes. Returns nil for other formats.
    public static func pcm16(_ data: Data) -> (samples: [Float], sampleRate: Int)? {
        let bytes = [UInt8](data)
        func u32(_ at: Int) -> Int { Int(bytes[at]) | Int(bytes[at + 1]) << 8 | Int(bytes[at + 2]) << 16 | Int(bytes[at + 3]) << 24 }
        func u16(_ at: Int) -> Int { Int(bytes[at]) | Int(bytes[at + 1]) << 8 }
        guard bytes.count >= 12, Array(bytes[0..<4]) == Array("RIFF".utf8), Array(bytes[8..<12]) == Array("WAVE".utf8) else { return nil }
        var offset = 12, channels = 0, rate = 0, bits = 0, format = 0
        while offset + 8 <= bytes.count {
            let id = String(decoding: bytes[offset..<offset + 4], as: UTF8.self)
            let size = u32(offset + 4)
            let body = offset + 8
            if id == "fmt ", body + 16 <= bytes.count {
                format = u16(body); channels = u16(body + 2); rate = u32(body + 4); bits = u16(body + 14)
            } else if id == "data" {
                guard format == 1, bits == 16, channels > 0, rate > 0 else { return nil }
                let end = min(bytes.count, body + size)
                let frames = (end - body) / (2 * channels)
                var samples = [Float](repeating: 0, count: frames)
                for frame in 0..<frames {
                    var sum: Float = 0
                    for channel in 0..<channels {
                        let at = body + (frame * channels + channel) * 2
                        sum += Float(Int16(bitPattern: UInt16(u16(at)))) / 32768
                    }
                    samples[frame] = sum / Float(channels)
                }
                return (samples, rate)
            }
            offset = body + size + (size & 1)
        }
        return nil
    }
}

/// A timed piece of text from a transducer model. A leading space starts a new word.
public struct TimedPiece: Sendable, Equatable {
    public var text: String
    public var start: Double
    public var end: Double
    public init(text: String, start: Double, end: Double) { self.text = text; self.start = start; self.end = end }
}

public struct TimedSentence: Sendable, Equatable {
    public var text: String
    public var pieces: [TimedPiece]
    public init(text: String, pieces: [TimedPiece]) { self.text = text; self.pieces = pieces }
}

public enum VerboseJSON {
    /// The subset of whisper-server's `verbose_json` that `TranscriptOutput.parseServer` reads.
    public static func encode(_ sentences: [TimedSentence], language: String?, duration: Double) throws -> Data {
        struct Word: Encodable { let word: String; let start: Double; let end: Double }
        struct Segment: Encodable { let id: Int; let start: Double; let end: Double; let text: String; let words: [Word] }
        struct Output: Encodable { let language: String?; let duration: Double; let text: String; let segments: [Segment] }
        let segments = sentences.enumerated().compactMap { index, sentence -> Segment? in
            let text = sentence.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            let words = sentence.pieces.map { Word(word: $0.text, start: $0.start, end: $0.end) }
            return Segment(id: index, start: sentence.pieces.first?.start ?? 0, end: sentence.pieces.last?.end ?? duration,
                           text: " " + text, words: words)
        }
        let output = Output(language: language, duration: duration,
                            text: segments.map { $0.text.trimmingCharacters(in: .whitespaces) }.joined(separator: " "), segments: segments)
        return try JSONEncoder().encode(output)
    }
}

/// Reads a mono 16-bit PCM WAV file in pieces, so hour-long files never sit in memory as floats.
public final class PCM16WAVFile {
    public let sampleRate: Int
    public let sampleCount: Int
    private let handle: FileHandle
    private let dataOffset: UInt64

    public init(url: URL) throws {
        handle = try FileHandle(forReadingFrom: url)
        let header = try handle.read(upToCount: 4096) ?? Data()
        let bytes = [UInt8](header)
        func u32(_ at: Int) -> Int { Int(bytes[at]) | Int(bytes[at + 1]) << 8 | Int(bytes[at + 2]) << 16 | Int(bytes[at + 3]) << 24 }
        func u16(_ at: Int) -> Int { Int(bytes[at]) | Int(bytes[at + 1]) << 8 }
        guard bytes.count >= 12, Array(bytes[0..<4]) == Array("RIFF".utf8), Array(bytes[8..<12]) == Array("WAVE".utf8) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        var offset = 12, rate = 0, format = 0, channels = 0, bits = 0
        var found: (offset: Int, size: Int)?
        while offset + 8 <= bytes.count {
            let id = String(decoding: bytes[offset..<offset + 4], as: UTF8.self)
            let size = u32(offset + 4)
            if id == "fmt ", offset + 24 <= bytes.count {
                format = u16(offset + 8); channels = u16(offset + 10); rate = u32(offset + 12); bits = u16(offset + 22)
            } else if id == "data" {
                found = (offset + 8, size)
                break
            }
            offset += 8 + size + (size & 1)
        }
        guard let found, format == 1, channels == 1, bits == 16, rate > 0 else { throw CocoaError(.fileReadCorruptFile) }
        let fileSize = Int(try handle.seekToEnd())
        sampleRate = rate
        dataOffset = UInt64(found.offset)
        // ffmpeg writes a placeholder size when it cannot seek back; trust the file length then.
        sampleCount = (found.size == 0 || found.size == 0xFFFF_FFFF ? fileSize - found.offset : min(found.size, fileSize - found.offset)) / 2
    }

    deinit { try? handle.close() }

    public func read(_ range: Range<Int>) throws -> [Float] {
        let lower = max(0, range.lowerBound), upper = min(sampleCount, range.upperBound)
        guard lower < upper else { return [] }
        try handle.seek(toOffset: dataOffset + UInt64(lower * 2))
        let data = try handle.read(upToCount: (upper - lower) * 2) ?? Data()
        return data.withUnsafeBytes { raw in
            raw.bindMemory(to: Int16.self).map { Float(Int16(littleEndian: $0)) / 32768 }
        }
    }

    /// `LongAudioPlan.blockRMS` of the whole file, read about 6 MB at a time.
    public func blockRMS() throws -> [Float] {
        var values: [Float] = []
        let step = LongAudioPlan.blockSize * 4000
        var start = 0
        while start < sampleCount {
            values += LongAudioPlan.blockRMS(try read(start..<min(sampleCount, start + step))[...])
            start += step
        }
        return values
    }
}
