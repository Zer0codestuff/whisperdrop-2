import XCTest
@testable import WhisperDropCore

final class LongAudioTests: XCTestCase {
    private let rate = whisperSampleRate

    private func tone(_ seconds: Double, level: Float = 0.2) -> [Float] {
        (0..<Int(seconds * Double(rate))).map { level * sin(Float($0) * 0.05) }
    }

    func testShortAudioIsOneWindow() {
        XCTAssertEqual(LongAudioPlan.windows(tone(35)), [0..<35 * rate])
        XCTAssertEqual(LongAudioPlan.windows([]), [])
    }

    func testLongAudioCutsInsideThePause() {
        // 28 s of speech, 1 s of silence, 20 s of speech: the cut lands in the middle of the silence.
        let samples = tone(28) + [Float](repeating: 0, count: rate) + tone(20)
        let windows = LongAudioPlan.windows(samples)
        XCTAssertEqual(windows.count, 2)
        XCTAssertEqual(Double(windows[0].upperBound) / Double(rate), 28.5, accuracy: 0.05)
        XCTAssertEqual(windows[1].upperBound, samples.count)
    }

    func testContinuousSpeechCutsAtThirtySecondsAndCoversEverything() {
        let samples = tone(100)
        let windows = LongAudioPlan.windows(samples)
        XCTAssertEqual(windows.first?.upperBound, 30 * rate)
        XCTAssertEqual(windows.first?.lowerBound, 0)
        XCTAssertEqual(windows.last?.upperBound, samples.count)
        for (left, right) in zip(windows, windows.dropFirst()) { XCTAssertEqual(left.upperBound, right.lowerBound) }
        XCTAssertTrue(windows.allSatisfy { $0.count <= 35 * rate })
    }

    func testWAVDecoderReadsEncoderOutput() throws {
        let samples: [Float] = [0, 0.5, -0.5, 0.25]
        let decoded = try XCTUnwrap(WAVDecoder.pcm16(WAVEncoder.pcm16(samples)))
        XCTAssertEqual(decoded.sampleRate, rate)
        XCTAssertEqual(decoded.samples.count, 4)
        for (a, b) in zip(decoded.samples, samples) { XCTAssertEqual(a, b, accuracy: 1.0 / 16384) }
        XCTAssertNil(WAVDecoder.pcm16(Data("not a wav".utf8)))
    }

    func testPCM16FileReadsRangesAndBlockEnergy() throws {
        let samples = tone(3) + [Float](repeating: 0, count: rate)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("long-audio-\(UUID().uuidString).wav")
        try WAVEncoder.pcm16(samples).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let file = try PCM16WAVFile(url: url)
        XCTAssertEqual(file.sampleCount, samples.count)
        XCTAssertEqual(try file.read(100..<104).count, 4)
        XCTAssertEqual(try file.read(100..<104)[1], samples[101], accuracy: 1.0 / 16384)
        let rms = try file.blockRMS()
        XCTAssertEqual(rms.count, samples.count / LongAudioPlan.blockSize)
        XCTAssertGreaterThan(rms[0], 0.1)
        XCTAssertEqual(rms.last ?? 1, 0, accuracy: 1e-6)
    }

    func testTransducerJSONMatchesTheServerParser() throws {
        let sentence = TimedSentence(text: "Ciao a tutti.", pieces: [
            TimedPiece(text: " Ci", start: 0.4, end: 0.5), TimedPiece(text: "ao", start: 0.5, end: 0.7),
            TimedPiece(text: " a", start: 0.8, end: 0.9), TimedPiece(text: " tutti", start: 0.9, end: 1.2), TimedPiece(text: ".", start: 1.2, end: 1.3)
        ])
        let data = try VerboseJSON.encode([sentence, TimedSentence(text: "  ", pieces: [])], language: "it", duration: 2)
        let result = try TranscriptOutput.parseServer(data, offset: 10)
        XCTAssertEqual(result.language, "it")
        XCTAssertEqual(result.segments.count, 1)
        XCTAssertEqual(result.text, "Ciao a tutti.")
        XCTAssertEqual(result.segments[0].start, 10.4, accuracy: 1e-9)
        XCTAssertEqual(result.segments[0].end, 11.3, accuracy: 1e-9)
        XCTAssertEqual(result.segments[0].words?.map(\.text), [" Ciao", " a", " tutti."])
        XCTAssertEqual(result.segments[0].words?.first?.end ?? 0, 10.7, accuracy: 1e-9)
    }

    func testCatalogStorageAndLanguages() throws {
        let parakeet = try XCTUnwrap(TranscriptionModel.catalog.first { $0.engine == .parakeet })
        let turbo = try XCTUnwrap(TranscriptionModel.catalog.first { $0.id == "turbo" })
        let folder = URL(fileURLWithPath: "/tmp/Models")
        XCTAssertEqual(TranscriptionModel.catalog[4].id, "turbo")
        XCTAssertEqual(turbo.location(in: folder).lastPathComponent, "ggml-large-v3-turbo-q5_0.bin")
        XCTAssertEqual(parakeet.fileLocation(parakeet.files[1], in: folder).path, "/tmp/Models/parakeet-v3/model.safetensors")
        XCTAssertTrue(parakeet.experimental)
        XCTAssertFalse(parakeet.usesPrompt)
        XCTAssertTrue(parakeet.supports(language: "it"))
        XCTAssertTrue(parakeet.supports(language: "auto"))
        XCTAssertFalse(parakeet.supports(language: "ja"))
        XCTAssertTrue(turbo.supports(language: "ja"))
        XCTAssertEqual(parakeet.bytes, 488_831_119)
        XCTAssertTrue(parakeet.files.allSatisfy { $0.url.absoluteString.contains("/resolve/aa25511e86a4a83285774ba03df07ca62069de2f/") })
        XCTAssertEqual(Set(TranscriptionModel.catalog.map(\.id)).count, TranscriptionModel.catalog.count)
    }
}

final class OpenTailTests: XCTestCase {
    func testOpenTailIsReadOnlyAndCarriesAbsoluteStart() throws {
        var chunker = Chunker.lecture
        let speech = (0..<(whisperSampleRate * 10)).map { 0.1 * sin(Float($0) * 0.05) }
        XCTAssertTrue(chunker.append(speech).isEmpty)
        let tail = try XCTUnwrap(chunker.openTail(lastSeconds: 4))
        XCTAssertEqual(tail.samples.count, whisperSampleRate * 4)
        XCTAssertEqual(tail.start, 6, accuracy: 0.01)
        XCTAssertTrue(tail.hasSpeech)
        // Reading the tail must not change what the chunker emits later.
        let whole = try XCTUnwrap(chunker.flush())
        XCTAssertEqual(whole.samples.count, speech.count, accuracy: Int(Chunker.Options.lecture.preRoll * Double(whisperSampleRate)))
    }

    func testSilentTailHasNoSpeech() {
        var chunker = Chunker.lecture
        _ = chunker.append([Float](repeating: 0, count: whisperSampleRate))
        XCTAssertFalse(chunker.openTail(lastSeconds: 5)?.hasSpeech ?? false)
        XCTAssertNil(Chunker.lecture.openTail(lastSeconds: 5))
    }
}
