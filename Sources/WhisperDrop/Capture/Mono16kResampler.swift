import AVFoundation
import Foundation

/// Converts PCM to 16 kHz mono Float32.
///
/// `primeMethod` is `.none` so a live stream is not asked for samples that have not arrived yet.
/// Each buffer ends with `.noDataNow`, which keeps the converter's filter state for the next buffer.
final class Mono16kResampler {
    static let targetRate: Double = 16_000

    private let targetFormat: AVAudioFormat
    private var converter: AVAudioConverter?
    private var sourceRate: Double = 0
    private var sourceChannels: AVAudioChannelCount = 0
    private var sourceInterleaved = false
    private var sourceCommonFormat: AVAudioCommonFormat = .otherFormat

    init() {
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Self.targetRate,
            channels: 1,
            interleaved: false
        ) else {
            fatalError("16 kHz mono float format is always valid")
        }
        targetFormat = format
    }

    func convert(buffer: AVAudioPCMBuffer) -> [Float] {
        let source = buffer.format
        guard source.sampleRate > 0, buffer.frameLength > 0 else { return [] }
        if source.sampleRate == Self.targetRate,
           source.channelCount == 1,
           source.commonFormat == .pcmFormatFloat32,
           let channel = buffer.floatChannelData?[0] {
            return Array(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
        }
        prepareConverter(matching: source)
        guard let converter else { return [] }

        let ratio = Self.targetRate / source.sampleRate
        let capacity = max(AVAudioFrameCount(ceil(Double(buffer.frameLength) * ratio)) + 64, 64)
        guard let output = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else { return [] }

        var supplied = false
        var collected: [Float] = []
        collected.reserveCapacity(Int(Double(buffer.frameLength) * ratio) + 64)
        // A short output buffer, or converter delay, can take more than one pull.
        for _ in 0..<8 {
            output.frameLength = 0
            var error: NSError?
            let status = converter.convert(to: output, error: &error) { _, outStatus in
                if supplied {
                    outStatus.pointee = .noDataNow
                    return nil
                }
                supplied = true
                outStatus.pointee = .haveData
                return buffer
            }
            if let channel = output.floatChannelData?[0], output.frameLength > 0 {
                collected.append(contentsOf: UnsafeBufferPointer(start: channel, count: Int(output.frameLength)))
            }
            if error != nil || status != .haveData || output.frameLength == 0 {
                break
            }
        }
        return collected
    }

    /// Pulls samples still inside the converter, then drops it. Call only after input has stopped.
    func flush() -> [Float] {
        guard let converter else { return [] }
        defer {
            self.converter = nil
            sourceRate = 0
            sourceChannels = 0
        }
        guard let output = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: 4_096) else { return [] }
        var collected: [Float] = []
        for _ in 0..<8 {
            output.frameLength = 0
            var error: NSError?
            let status = converter.convert(to: output, error: &error) { _, outStatus in
                outStatus.pointee = .endOfStream
                return nil
            }
            if let channel = output.floatChannelData?[0], output.frameLength > 0 {
                collected.append(contentsOf: UnsafeBufferPointer(start: channel, count: Int(output.frameLength)))
            }
            if error != nil || output.frameLength == 0 || status == .endOfStream || status == .error {
                break
            }
        }
        return collected
    }

    private func prepareConverter(matching source: AVAudioFormat) {
        if converter != nil,
           sourceRate == source.sampleRate,
           sourceChannels == source.channelCount,
           sourceInterleaved == source.isInterleaved,
           sourceCommonFormat == source.commonFormat {
            return
        }
        converter = AVAudioConverter(from: source, to: targetFormat)
        converter?.primeMethod = .none
        sourceRate = source.sampleRate
        sourceChannels = source.channelCount
        sourceInterleaved = source.isInterleaved
        sourceCommonFormat = source.commonFormat
    }
}
