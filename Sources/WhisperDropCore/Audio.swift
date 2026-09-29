import Foundation

/// Contract file. Signatures are fixed; bodies are implemented by the core worker.

/// 16 kHz mono Float samples in -1...1 are used everywhere.
public let whisperSampleRate = 16_000

public enum SpeechDetector {
    /// RMS at or above this level is speech. About -36.5 dBFS, above a quiet noise floor.
    private static let speechRMS: Float = 0.015
    /// 20 ms at 16 kHz. Frames stay aligned with the chunker.
    private static let frameSamples = 320

    /// Root mean square level of a buffer, 0...1.
    public static func rms(_ samples: ArraySlice<Float>) -> Float {
        guard !samples.isEmpty else { return 0 }
        var sum: Float = 0
        for sample in samples {
            sum += sample * sample
        }
        return (sum / Float(samples.count)).squareRoot()
    }

    /// True when the buffer likely contains speech (energy based, robust to low constant noise).
    public static func hasSpeech(_ samples: [Float]) -> Bool {
        guard !samples.isEmpty else { return false }
        let frame = frameSamples
        if samples.count < frame {
            return rms(samples[...]) >= speechRMS
        }
        var offset = 0
        while offset + frame <= samples.count {
            if rms(samples[offset..<(offset + frame)]) >= speechRMS { return true }
            offset += frame
        }
        let tail = samples.count - offset
        if tail > 0, rms(samples[offset...]) >= speechRMS { return true }
        return false
    }

    /// Removes leading and trailing silence, keeping `padding` seconds around speech.
    public static func trimSilence(_ samples: [Float], padding: Double = 0.2) -> [Float] {
        guard !samples.isEmpty else { return [] }
        let frame = frameSamples
        if samples.count < frame {
            return rms(samples[...]) >= speechRMS ? samples : []
        }
        let frames = samples.count / frame
        var first: Int?
        var last: Int?
        for index in 0..<frames {
            let start = index * frame
            if rms(samples[start..<(start + frame)]) >= speechRMS {
                if first == nil { first = start }
                last = start + frame
            }
        }
        guard let first, let last else { return [] }
        let pad = padding > 0
            ? Int((padding * Double(whisperSampleRate)).rounded(.toNearestOrAwayFromZero))
            : 0
        let from = max(0, first - pad)
        let to = min(samples.count, last + pad)
        guard from < to else { return [] }
        return Array(samples[from..<to])
    }
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

    /// Thresholds from the meeting chunker. Sample counts are exact at 16 kHz and on the 20 ms grid.
    private enum Gate {
        static let frame = 320
        static let speechRMS: Float = 0.015
        static let preRoll = 4_800
        static let tailPad = 1_280
        static let minSilence = 6_400
        static let longPause = 48_000
        static let bandStart = 240_000
        static let earlyCut = 400_000
        static let minSpeech = 4_800
    }

    // `storage[head...]` is the uncommitted tail. `absoluteSample` is the recording index of that tail.
    // Frame RMS is appended only for newly completed frames, so each append is O(new samples) amortized.
    private var storage: [Float] = []
    private var head = 0
    private var absoluteSample = 0
    private var frameRMS: [Float] = []
    private var frameHead = 0
    private var framedSamples = 0

    public init(target: Double = 20, maxLength: Double = 28, minLength: Double = 1) {
        self.target = target
        self.maxLength = maxLength
        self.minLength = minLength
    }

    private var pendingCount: Int { storage.count - head }
    private var cachedFrames: Int { frameRMS.count - frameHead }

    /// Feeds new samples and returns any chunks that are complete.
    public mutating func append(_ samples: [Float]) -> [AudioChunk] {
        guard !samples.isEmpty, maxLength > 0, whisperSampleRate > 0 else { return [] }
        let needed = storage.count + samples.count
        if storage.capacity < needed {
            storage.reserveCapacity(needed + max(samples.count, sampleCount(for: maxLength)))
        }
        storage.append(contentsOf: samples)
        cacheNewFrames()
        return drain(flush: false)
    }

    /// Returns the remaining buffered audio as a final chunk, if it contains enough speech.
    /// `append` already emitted every finished cut, so the tail is at most `maxLength`.
    public mutating func flush() -> AudioChunk? {
        while pendingCount > 0 {
            trimLeadingSilence()
            if pendingCount == 0 { return nil }
            let hard = sampleCount(for: maxLength)
            let cut = hard > 0 ? min(pendingCount, hard) : pendingCount
            guard cut > 0 else { return nil }
            let speechSamples = speechSampleCount(prefix: cut)
            if speechSamples >= Gate.minSpeech {
                let chunk = makeChunk(sampleCount: cut, speechSamples: speechSamples)
                discardPrefix(cut)
                return chunk
            }
            discardPrefix(cut)
        }
        return nil
    }

    private mutating func drain(flush: Bool) -> [AudioChunk] {
        var emitted: [AudioChunk] = []
        var spins = 0
        while spins < 10_000 {
            spins += 1
            let before = pendingCount
            trimLeadingSilence()
            guard let cut = selectCut(flush: flush), cut > 0 else { break }
            let speechSamples = speechSampleCount(prefix: cut)
            let longEnough = flush || cut >= sampleCount(for: minLength)
            if longEnough && speechSamples >= Gate.minSpeech {
                emitted.append(makeChunk(sampleCount: cut, speechSamples: speechSamples))
            }
            discardPrefix(cut)
            if pendingCount >= before && pendingCount > 0 { break }
        }
        return emitted
    }

    private func selectCut(flush: Bool) -> Int? {
        if pendingCount == 0 { return nil }
        if let live = selectLiveCut() { return live }
        if flush { return pendingCount }
        return nil
    }

    /// Open 3 s pause, then the longest pause in the 15 s...maxLength band, else a hard cut.
    private func selectLiveCut() -> Int? {
        let count = pendingCount
        if count == 0 { return nil }
        let hard = sampleCount(for: maxLength)
        if hard <= 0 { return nil }
        let early = min(Gate.earlyCut, hard)
        let floor = sampleCount(for: minLength)
        let runs = silenceRuns()

        if let trail = runs.last(where: \.reachesEnd),
           trail.length >= Gate.longPause,
           trail.start >= floor {
            return cutPoint(trail, limit: min(count, hard), floor: floor)
        }
        if count < Gate.bandStart && count < hard { return nil }

        let searchEnd = min(count, hard)
        let eligible = runs.filter { run in
            run.length >= Gate.minSilence && run.start >= Gate.bandStart && run.start < searchEnd
        }
        if count >= hard {
            if let best = bestRun(eligible) {
                return cutPoint(best, limit: min(hard, count), floor: floor)
            }
            return min(hard, count)
        }
        if count >= early {
            let closed = eligible.filter { !$0.reachesEnd }
            if let best = bestRun(closed) {
                return cutPoint(best, limit: count, floor: floor)
            }
        }
        return nil
    }

    private struct SilenceRun {
        var start: Int
        var end: Int
        var reachesEnd: Bool
        var length: Int { end - start }
    }

    private func silenceRuns() -> [SilenceRun] {
        let frames = cachedFrames
        guard frames > 0 else { return [] }
        var runs: [SilenceRun] = []
        var index = 0
        while index < frames {
            if frameRMS[frameHead + index] < Gate.speechRMS {
                var next = index + 1
                while next < frames, frameRMS[frameHead + next] < Gate.speechRMS {
                    next += 1
                }
                runs.append(SilenceRun(
                    start: index * Gate.frame,
                    end: next * Gate.frame,
                    reachesEnd: next == frames
                ))
                index = next
            } else {
                index += 1
            }
        }
        return runs
    }

    private func bestRun(_ runs: [SilenceRun]) -> SilenceRun? {
        let targetSamples = sampleCount(for: target)
        return runs.max { lhs, rhs in
            if lhs.length != rhs.length { return lhs.length < rhs.length }
            return abs(lhs.start - targetSamples) > abs(rhs.start - targetSamples)
        }
    }

    private func cutPoint(_ run: SilenceRun, limit: Int, floor: Int) -> Int {
        guard limit > 0 else { return 0 }
        var cut = run.start + Gate.tailPad
        if cut > run.end { cut = run.end }
        if cut > limit { cut = limit }
        if cut < floor { cut = min(floor, limit) }
        if cut < 1 { cut = min(1, limit) }
        return cut
    }

    private mutating func trimLeadingSilence() {
        let frames = cachedFrames
        var speechAt: Int?
        if frames > 0 {
            for index in 0..<frames where frameRMS[frameHead + index] >= Gate.speechRMS {
                speechAt = index * Gate.frame
                break
            }
        }
        if let speechAt {
            let drop = speechAt - Gate.preRoll
            if drop > 0 { discardPrefix(drop) }
        } else if pendingCount > Gate.preRoll {
            discardPrefix(pendingCount - Gate.preRoll)
        }
    }

    private func speechSampleCount(prefix count: Int) -> Int {
        let frames = min(count, framedSamples) / Gate.frame
        var speechFrames = 0
        for index in 0..<frames where frameRMS[frameHead + index] >= Gate.speechRMS {
            speechFrames += 1
        }
        return speechFrames * Gate.frame
    }

    private func makeChunk(sampleCount: Int, speechSamples: Int) -> AudioChunk {
        let count = min(sampleCount, pendingCount)
        let samples = Array(storage[head..<(head + count)])
        let start = Double(absoluteSample) / Double(whisperSampleRate)
        return AudioChunk(start: start, samples: samples, hasSpeech: speechSamples >= Gate.minSpeech)
    }

    private mutating func cacheNewFrames() {
        let frame = Gate.frame
        var offset = framedSamples
        while offset + frame <= pendingCount {
            let start = head + offset
            frameRMS.append(SpeechDetector.rms(storage[start..<(start + frame)]))
            offset += frame
        }
        framedSamples = offset
    }

    private mutating func discardPrefix(_ count: Int) {
        guard count > 0 else { return }
        let dropping = min(count, pendingCount)
        absoluteSample += dropping
        if dropping == pendingCount {
            head += dropping
            clearFrameCache()
        } else if dropping % Gate.frame == 0, framedSamples >= dropping {
            head += dropping
            frameHead += dropping / Gate.frame
            framedSamples -= dropping
            compactFrameCacheIfNeeded()
        } else {
            head += dropping
            rebuildFrameCache()
        }
        compactStorageIfNeeded()
    }

    private mutating func clearFrameCache() {
        frameRMS.removeAll(keepingCapacity: true)
        frameHead = 0
        framedSamples = 0
    }

    private mutating func rebuildFrameCache() {
        clearFrameCache()
        cacheNewFrames()
    }

    private mutating func compactFrameCacheIfNeeded() {
        if frameHead > 1_024, frameHead > frameRMS.count / 2 {
            frameRMS.removeFirst(frameHead)
            frameHead = 0
        }
    }

    /// Drops consumed samples so a multi-hour recording retains only the open tail.
    private mutating func compactStorageIfNeeded() {
        guard head >= 480_000, head > pendingCount else { return }
        if pendingCount == 0 {
            storage.removeAll(keepingCapacity: false)
        } else {
            storage = Array(storage[head...])
        }
        head = 0
    }

    private func sampleCount(for seconds: Double) -> Int {
        guard seconds > 0, whisperSampleRate > 0 else { return 0 }
        let value = seconds * Double(whisperSampleRate)
        guard value.isFinite else { return 0 }
        return Int(value.rounded(.toNearestOrAwayFromZero))
    }
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
