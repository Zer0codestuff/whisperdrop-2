import XCTest
@testable import WhisperDropCore

final class AudioPreprocessorTests: XCTestCase {
    private func voice(amplitude: Float, seconds: Int = 3) -> [Float] {
        (0..<(seconds * whisperSampleRate)).map { index in
            let envelope: Float = index % 16_000 < 10_000 ? 1 : 0.01
            return amplitude * envelope * sin(2 * .pi * Float(index) * 220 / Float(whisperSampleRate))
        }
    }

    func testQuietVoiceGetsBoundedGainAndKeepsTiming() {
        let input = voice(amplitude: 0.01)
        let result = AudioPreprocessor.prepare(input)
        XCTAssertEqual(result.samples.count, input.count)
        XCTAssertGreaterThan(result.gain, 1)
        XCTAssertLessThanOrEqual(result.gain, 4)
        XCTAssertGreaterThan(SpeechDetector.rms(result.samples[...]), SpeechDetector.rms(input[...]) * 2)
    }

    func testNormalVoiceSilenceAndSteadyHumAreUnchanged() {
        for input in [voice(amplitude: 0.2), [Float](repeating: 0, count: 32_000), [Float](repeating: 0.01, count: 32_000)] {
            let result = AudioPreprocessor.prepare(input)
            XCTAssertEqual(result.gain, 1)
            XCTAssertEqual(result.samples, input)
        }
    }

    func testQuietChangingNoiseDoesNotTriggerGain() {
        let input: [Float] = (0..<48_000).map { index in
            let amplitude: Float = index % 16_000 < 8_000 ? 0.006 : 0.012
            return amplitude * sin(2 * .pi * Float(index) * 220 / 16_000)
        }
        XCTAssertEqual(AudioPreprocessor.prepare(input).samples, input)
    }

    func testNearbyLoudTransientDoesNotClipBoostedVoice() {
        var input = voice(amplitude: 0.01)
        input[10_000] = 0.99; input[10_001] = -0.99
        let result = AudioPreprocessor.prepare(input)
        XCTAssertGreaterThan(result.gain, 1)
        XCTAssertEqual(result.samples.count, input.count)
        XCTAssertLessThanOrEqual(result.samples.map(abs).max() ?? 0, 0.98001)
        XCTAssertGreaterThan(abs(result.samples[20_015]), abs(input[20_015]) * 2)
    }

    func testInvalidSamplesCannotReachPCMEncoder() {
        let result = AudioPreprocessor.prepare([.nan, .infinity, -.infinity, 0.01])
        XCTAssertTrue(result.samples.allSatisfy(\.isFinite))
        XCTAssertEqual(result.samples.count, 4)
    }

    func testGainIsRestrictedToVoiceWithoutCuttingWeakSpeechOutsideItsRanges() {
        let input = voice(amplitude: 0.01)
        let prepared = AudioPreprocessor.prepare(input)
        let result = AudioPreprocessor.restrict(prepared, original: input,
            speech: [SpeechRange(start: 10.2, end: 10.5)], offset: 10)
        XCTAssertEqual(result.samples.count, input.count)
        XCTAssertTrue(result.samples[8_000...].elementsEqual(input[8_000...]))
        XCTAssertTrue(result.samples[..<3_200].elementsEqual(input[..<3_200]))
        XCTAssertGreaterThan(SpeechDetector.rms(result.samples[4_000..<7_000]), SpeechDetector.rms(input[4_000..<7_000]) * 2)
        XCTAssertEqual(AudioPreprocessor.restrict(prepared, original: input, speech: []).samples, input)
    }
}
