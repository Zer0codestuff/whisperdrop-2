import AVFoundation
import XCTest
@testable import WhisperDrop

final class CaptureTests: XCTestCase {
    func testHandoffKeepsCaptureOrderWhenEarlierSlotsAreReused() throws {
        let firstEntered = DispatchSemaphore(value: 0)
        let releaseFirst = DispatchSemaphore(value: 0)
        let secondEntered = DispatchSemaphore(value: 0)
        let releaseSecond = DispatchSemaphore(value: 0)
        let lock = NSLock()
        var values: [Int] = []
        let queue = PCMSlotQueue(payloadCapacity: 4096, label: "test.capture-order") { packet in
            let value = Int((packet.payload.load(as: Float.self) * 100).rounded())
            lock.lock(); values.append(value); lock.unlock()
            if value == 1 { firstEntered.signal(); _ = releaseFirst.wait(timeout: .now() + 5) }
            if value == 2 { secondEntered.signal(); _ = releaseSecond.wait(timeout: .now() + 5) }
        }
        queue.start()
        queue.publish(try numberedBuffer(1))
        XCTAssertEqual(firstEntered.wait(timeout: .now() + 5), .success)
        for value in 2...4 { queue.publish(try numberedBuffer(value)) }
        releaseFirst.signal()
        XCTAssertEqual(secondEntered.wait(timeout: .now() + 5), .success)
        queue.publish(try numberedBuffer(5))
        releaseSecond.signal()
        queue.stop()
        XCTAssertEqual(values, [1, 2, 3, 4, 5])
        XCTAssertEqual(queue.droppedPacketCount, 0)
    }

    func testHandoffReportsOverflowAndDrainsAcceptedPackets() throws {
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let lock = NSLock()
        var delivered = 0
        let queue = PCMSlotQueue(payloadCapacity: 4096, label: "test.capture-overflow") { _ in
            lock.lock(); delivered += 1; let first = delivered == 1; lock.unlock()
            if first { entered.signal(); _ = release.wait(timeout: .now() + 5) }
        }
        queue.start()
        let buffer = try numberedBuffer(1)
        queue.publish(buffer)
        XCTAssertEqual(entered.wait(timeout: .now() + 5), .success)
        for _ in 0..<64 { queue.publish(buffer) }
        XCTAssertGreaterThan(queue.droppedPacketCount, 0)
        release.signal()
        queue.stop()
        XCTAssertEqual(delivered + queue.droppedPacketCount, 65)
    }

    func testClosingWriterDrainsQueuedAudioInOrder() throws {
        let url = temporaryCAF()
        defer { try? FileManager.default.removeItem(at: url) }
        let writer = try AudioFileWriter(url: url)
        for index in 0..<100 { writer.append([Float](repeating: Float(index) / 100, count: 320)) }
        writer.close()
        let file = try AVAudioFile(forReading: url)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 32_000))
        try file.read(into: buffer)
        XCTAssertEqual(file.length, 32_000)
        let samples = try XCTUnwrap(buffer.floatChannelData?[0])
        for index in 0..<100 { XCTAssertEqual(samples[index * 320], Float(index) / 100, accuracy: 0.0001) }
        XCTAssertFalse(writer.hasFailed)
    }

    private func numberedBuffer(_ value: Int) throws -> AVAudioPCMBuffer {
        let format = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 320))
        buffer.frameLength = 320
        for index in 0..<320 { buffer.floatChannelData![0][index] = Float(value) / 100 }
        return buffer
    }

    func testAudioFileRoundTrip() throws {
        let url = temporaryCAF()
        defer { try? FileManager.default.removeItem(at: url) }
        let writer = try AudioFileWriter(url: url)
        let first = sine(count: 1_600, amplitude: 0.25)
        let second = sine(count: 3_200, amplitude: 0.5)
        writer.append(first)
        writer.append([])
        writer.append(second)
        writer.close()
        writer.close()

        let file = try AVAudioFile(forReading: url)
        XCTAssertEqual(file.fileFormat.sampleRate, 16_000, accuracy: 0.001)
        XCTAssertEqual(file.fileFormat.channelCount, 1)
        XCTAssertEqual(file.fileFormat.commonFormat, .pcmFormatInt16)
        XCTAssertEqual(file.length, AVAudioFramePosition(first.count + second.count))

        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)) else {
            XCTFail("Could not allocate a read buffer")
            return
        }
        try file.read(into: buffer)
        XCTAssertEqual(Int(buffer.frameLength), first.count + second.count)
    }

    func testFileIsReadableBeforeClose() throws {
        let url = temporaryCAF()
        defer { try? FileManager.default.removeItem(at: url) }
        let writer = try AudioFileWriter(url: url)
        let samples = sine(count: 16_000, amplitude: 0.2)
        writer.append(samples)
        writer.flush()

        let frames: AVAudioFramePosition
        let rate: Double
        do {
            let file = try AVAudioFile(forReading: url)
            rate = file.fileFormat.sampleRate
            frames = file.length
            XCTAssertEqual(file.fileFormat.channelCount, 1)
        }
        XCTAssertEqual(rate, 16_000, accuracy: 0.001)
        XCTAssertEqual(frames, AVAudioFramePosition(samples.count))
        writer.close()

        let closed = try AVAudioFile(forReading: url)
        XCTAssertEqual(closed.length, AVAudioFramePosition(samples.count))
        XCTAssertEqual(closed.fileFormat.sampleRate, 16_000, accuracy: 0.001)
    }

    func testResamplerConvertsStereo48kSineToMono16k() throws {
        let inputRate = 48_000
        let frames = inputRate
        let format = try XCTUnwrap(AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Double(inputRate),
            channels: 2,
            interleaved: false
        ))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)))
        buffer.frameLength = AVAudioFrameCount(frames)
        let left = try XCTUnwrap(buffer.floatChannelData?[0])
        let right = try XCTUnwrap(buffer.floatChannelData?[1])
        let amplitude = 0.5
        for frame in 0..<frames {
            let sample = Float(sin(2 * Double.pi * 440 * Double(frame) / Double(inputRate)) * amplitude)
            left[frame] = sample
            right[frame] = sample
        }

        let resampler = Mono16kResampler()
        let output = resampler.convert(buffer: buffer)
        let tail = resampler.flush()
        // 48000 frames at 48 kHz is 16000 frames at 16 kHz. primeMethod .none holds the
        // converter's filter delay until end-of-stream, so one live buffer is short by under 1200 frames.
        XCTAssertLessThanOrEqual(abs(output.count - 16_000), 1_200, "streamed \(output.count)")
        XCTAssertLessThanOrEqual(
            abs(output.count + tail.count - 16_000),
            64,
            "streamed \(output.count) tail \(tail.count)"
        )

        let start = output.count / 4
        let end = output.count * 3 / 4
        var peak: Float = 0
        var sum: Float = 0
        for sample in output[start..<end] {
            peak = max(peak, abs(sample))
            sum += sample * sample
        }
        let rms = sqrt(sum / Float(end - start))
        XCTAssertGreaterThan(peak, 0.35, "peak \(peak)")
        XCTAssertLessThan(peak, 0.65, "peak \(peak)")
        XCTAssertEqual(Double(rms), amplitude / 2.squareRoot(), accuracy: 0.08, "rms \(rms)")
    }

    func testPreallocatedHandoffPreservesFrames() throws {
        let delivered = expectation(description: "packet")
        let queue = PCMSlotQueue(payloadCapacity: 64_000, label: "test.slots") { packet in
            XCTAssertEqual(packet.frames, 32)
            let buffer = PCMBuffers.make(packet)
            XCTAssertEqual(buffer?.frameLength, 32)
            XCTAssertEqual(buffer?.floatChannelData?[0][0] ?? -1, 0.25, accuracy: 0.0001)
            XCTAssertEqual(buffer?.floatChannelData?[1][31] ?? -1, -0.5, accuracy: 0.0001)
            delivered.fulfill()
        }
        queue.start()
        defer { queue.stop() }

        let format = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 2, interleaved: false))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 32))
        buffer.frameLength = 32
        buffer.floatChannelData?[0][0] = 0.25
        buffer.floatChannelData?[1][31] = -0.5
        queue.publish(buffer)
        wait(for: [delivered], timeout: 2)
    }

    private func temporaryCAF() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("whisperdrop-capture-\(UUID().uuidString)")
            .appendingPathExtension("caf")
    }

    private func sine(count: Int, amplitude: Float) -> [Float] {
        (0..<count).map { index in
            Float(sin(2 * Double.pi * 440 * Double(index) / 16_000)) * amplitude
        }
    }
}
