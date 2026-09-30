import AVFoundation
import WhisperDropCore

enum AudioPreparation {
    struct Report: Sendable {
        var blocks = 0
        var boostedBlocks = 0
        var samples = 0
    }

    /// Bounded memory even for long imports. Output duration and sample count match the input.
    static func boostFile(at source: URL, to destination: URL, speech: [SpeechRange]? = nil) throws -> Report {
        let input = try AVAudioFile(forReading: source)
        guard input.processingFormat.sampleRate == 16_000, input.processingFormat.channelCount == 1,
              let buffer = AVAudioPCMBuffer(pcmFormat: input.processingFormat, frameCapacity: 960_000) else {
            throw AppFailure("Audio preparation requires 16 kHz mono audio.")
        }
        let output = try AVAudioFile(forWriting: destination, settings: [AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 16_000, AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false], commonFormat: .pcmFormatFloat32, interleaved: false)
        var report = Report()
        while input.framePosition < input.length {
            try Task.checkCancellation()
            try input.read(into: buffer)
            let count = Int(buffer.frameLength)
            guard count > 0, let channel = buffer.floatChannelData?[0] else { break }
            let start = Double(report.samples) / 16_000
            let end = start + Double(count) / 16_000
            var gain: Float = 1
            if speech == nil || speech!.contains(where: { min(end, $0.end) - max(start, $0.start) > 0.08 }) {
                let original = Array(UnsafeBufferPointer(start: channel, count: count))
                let candidate = AudioPreprocessor.prepare(original)
                let prepared = speech.map { AudioPreprocessor.restrict(candidate, original: original, speech: $0, offset: start) } ?? candidate
                gain = prepared.gain
                prepared.samples.withUnsafeBufferPointer { pointer in
                    if let base = pointer.baseAddress { channel.update(from: base, count: count) }
                }
            }
            try output.write(from: buffer)
            report.blocks += 1
            if gain > 1 { report.boostedBlocks += 1 }
            report.samples += count
        }
        guard report.samples == Int(input.length) else { throw AppFailure("Audio preparation did not preserve the complete recording.") }
        return report
    }
}
