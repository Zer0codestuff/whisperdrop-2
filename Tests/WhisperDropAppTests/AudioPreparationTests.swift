import AVFoundation
import XCTest
import WhisperDropCore
@testable import WhisperDrop

final class AudioPreparationTests: XCTestCase {
    func testImportedFileBoostPreservesSourceAndEverySample() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("WhisperDrop-audio-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let input = root.appendingPathComponent("original.wav"), output = root.appendingPathComponent("prepared.wav")
        let samples = (0..<(61 * 16_000 + 317)).map { index -> Float in
            let envelope: Float = index % 16_000 < 10_000 ? 1 : 0.01
            return 0.01 * envelope * sin(2 * .pi * Float(index) * 220 / 16_000)
        }
        let bytes = WAVEncoder.pcm16(samples)
        try bytes.write(to: input)
        let report = try AudioPreparation.boostFile(at: input, to: output)
        XCTAssertEqual(report.samples, samples.count)
        XCTAssertEqual(report.blocks, 2)
        XCTAssertEqual(report.boostedBlocks, 2)
        XCTAssertEqual(try Data(contentsOf: input), bytes)
        let file = try AVAudioFile(forReading: output)
        XCTAssertEqual(file.length, AVAudioFramePosition(samples.count))
        XCTAssertEqual(file.processingFormat.sampleRate, 16_000)
        XCTAssertEqual(file.processingFormat.channelCount, 1)
    }
}
