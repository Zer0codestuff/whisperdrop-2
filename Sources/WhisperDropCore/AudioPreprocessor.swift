import Foundation

/// A bounded gain adjustment for inference. The recorded samples remain untouched.
public enum AudioPreprocessor {
    public struct Result: Sendable {
        public let samples: [Float]
        public let gain: Float
        public let voiceLevel: Float
    }

    public static func prepare(_ samples: [Float]) -> Result {
        guard !samples.isEmpty else { return Result(samples: samples, gain: 1, voiceLevel: 0) }
        let frame = 320
        var levels: [Float] = []
        for start in stride(from: 0, to: samples.count, by: frame) {
            let end = min(samples.count, start + frame)
            let level = SpeechDetector.rms(samples[start..<end])
            if level.isFinite { levels.append(level) }
        }
        levels.sort()
        guard !levels.isEmpty else { return Result(samples: samples.map { $0.isFinite ? $0 : 0 }, gain: 1, voiceLevel: 0) }
        let voice = levels[Int(Double(levels.count - 1) * 0.7)]
        let floor = levels[Int(Double(levels.count - 1) * 0.1)]
        // A steady hum or nearly empty recording must not be amplified as speech.
        let gain: Float = voice >= 0.0005 && voice < 0.015 && voice > floor * 6
            ? min(4, 0.06 / voice) : 1
        guard gain > 1.15 else { return Result(samples: samples.map { $0.isFinite ? $0 : 0 }, gain: 1, voiceLevel: voice) }
        let clean = samples.map { $0.isFinite ? $0 : 0 }
        // Ten milliseconds of lookahead, with a 120 ms release. No samples are shifted or removed.
        let lookahead = 160
        let release: Float = 1 - exp(-1 / (0.12 * Float(whisperSampleRate)))
        var peaks = [Int](repeating: 0, count: clean.count)
        var head = 0, tail = 0, next = 0
        var limitingGain: Float = 1
        var output = clean
        for index in clean.indices {
            let end = min(clean.count, index + lookahead + 1)
            while next < end {
                while tail > head && abs(clean[peaks[tail - 1]]) <= abs(clean[next]) { tail -= 1 }
                peaks[tail] = next; tail += 1; next += 1
            }
            while head < tail && peaks[head] < index { head += 1 }
            let peak = head < tail ? abs(clean[peaks[head]]) * gain : 0
            let ceiling: Float = peak > 0.98 ? 0.98 / peak : 1
            limitingGain = min(ceiling, limitingGain + (1 - limitingGain) * release)
            output[index] = max(-0.98, min(0.98, clean[index] * gain * limitingGain))
        }
        return Result(samples: output, gain: gain, voiceLevel: voice)
    }

    /// Apply gain only around detected voice. Weak speech outside those ranges stays at its original level.
    public static func restrict(_ prepared: Result, original: [Float], speech: [SpeechRange], offset: Double = 0) -> Result {
        guard prepared.gain > 1, prepared.samples.count == original.count else { return prepared }
        var envelope = [Float](repeating: 0, count: original.count)
        let rate = Double(whisperSampleRate)
        let fade = 320
        for range in speech {
            guard range.start.isFinite, range.end.isFinite, offset.isFinite else { continue }
            let start = Int(max(0, min(Double(original.count), ((range.start - offset) * rate).rounded())))
            let end = Int(max(0, min(Double(original.count), ((range.end - offset) * rate).rounded())))
            guard end > start else { continue }
            for index in start..<end {
                let amount = min(1, Float(min(index - start + 1, end - index)) / Float(fade))
                envelope[index] = max(envelope[index], amount)
            }
        }
        var output = original.map { $0.isFinite ? $0 : 0 }
        for index in output.indices {
            output[index] += envelope[index] * (prepared.samples[index] - output[index])
        }
        return Result(samples: output, gain: envelope.contains(where: { $0 > 0 }) ? prepared.gain : 1,
                      voiceLevel: prepared.voiceLevel)
    }
}
