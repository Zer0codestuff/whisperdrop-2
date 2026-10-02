import Foundation
import WhisperDropCore

/// Feeds a 16 kHz mono WAV file to dictation at recording pace, for `--verify-dictation`. Nothing is played aloud.
final class DictationReplaySource: NoteCaptureSource, @unchecked Sendable {
    var onSamples: (@Sendable ([Float]) -> Void)?
    var onLevel: (@Sendable (Float) -> Void)?
    /// Called on a background queue when the file has been delivered.
    var onEnd: (@Sendable () -> Void)?
    var droppedPacketCount: Int { 0 }
    let duration: Double
    private let samples: [Float]
    private let queue = DispatchQueue(label: "whisperdrop.dictation-replay")
    private var timer: DispatchSourceTimer?
    private var position = 0

    init(file: URL) throws {
        guard let decoded = WAVDecoder.pcm16(try Data(contentsOf: file)), decoded.sampleRate == whisperSampleRate else {
            throw AppFailure("Dictation replay needs a 16 kHz 16-bit WAV file.")
        }
        samples = decoded.samples
        duration = Double(samples.count) / Double(whisperSampleRate)
    }

    func start() throws {
        queue.sync {
            position = 0
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now() + .milliseconds(20), repeating: .milliseconds(20))
            timer.setEventHandler { [weak self] in self?.deliver() }
            self.timer = timer
            timer.resume()
        }
    }

    func stop() {
        queue.sync {
            timer?.cancel()
            timer = nil
        }
    }

    private func deliver() {
        guard position < samples.count else {
            timer?.cancel()
            timer = nil
            onEnd?()
            return
        }
        let end = min(samples.count, position + 320)
        let packet = Array(samples[position..<end])
        position = end
        onSamples?(packet)
        onLevel?(SpeechDetector.rms(packet[...]))
    }
}
