import AVFoundation
import CoreAudio
import XCTest
@testable import WhisperDrop

final class CaptureTests: XCTestCase {
    /// Stereo packets of an odd size must come out as 100 ms mono chunks of the first channel, in order, with the tail on flush.
    func testInputChunkerKeepsTheFirstChannelInFixedChunks() throws {
        var source = AudioStreamBasicDescription(
            mSampleRate: 48_000, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 8, mFramesPerPacket: 1, mBytesPerFrame: 8, mChannelsPerFrame: 2, mBitsPerChannel: 32, mReserved: 0
        )
        let layout = try XCTUnwrap(InputChunker.Layout(source: source))
        XCTAssertEqual(layout.chunkFrames, 4_800)
        XCTAssertEqual(layout.stride, 2)
        source.mBitsPerChannel = 16
        XCTAssertNil(InputChunker.Layout(source: source))

        let lock = NSLock()
        var chunks: [[Float]] = []
        let queue = PCMSlotQueue(payloadCapacity: layout.chunkFrames * 4, label: "test.chunker") { packet in
            XCTAssertEqual(packet.format.mSampleRate, 48_000)
            XCTAssertEqual(packet.format.mChannelsPerFrame, 1)
            let floats = packet.payload.assumingMemoryBound(to: Float.self)
            lock.lock(); chunks.append(Array(UnsafeBufferPointer(start: floats, count: packet.frames))); lock.unlock()
        }
        queue.start()
        let chunker = InputChunker(layout: layout, queue: queue)
        // 20 packets of 512 frames: 10,240 frames, two full chunks and a 640-frame tail.
        var frame = 0
        for _ in 0..<20 {
            var packet = [Float](repeating: 0, count: 512 * 2)
            for index in 0..<512 {
                packet[index * 2] = Float(frame)
                packet[index * 2 + 1] = -1
                frame += 1
            }
            packet.withUnsafeMutableBytes { raw in
                var list = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(
                    mNumberChannels: 2, mDataByteSize: UInt32(raw.count), mData: raw.baseAddress
                ))
                chunker.append(&list)
            }
        }
        chunker.flush()
        queue.stop()
        XCTAssertEqual(chunks.map(\.count), [4_800, 4_800, 640])
        XCTAssertEqual(chunks.flatMap { $0 }, (0..<10_240).map(Float.init))
        XCTAssertEqual(queue.droppedPacketCount, 0)
    }

    /// Opt-in, discards all microphone samples. Verifies the actual capture route and repeated starts.
    func testMicrophoneStartsRepeatedlyWithCurrentHardware() throws {
        guard ProcessInfo.processInfo.environment["WHISPERDROP_VERIFY_MICROPHONE"] == "1" else {
            throw XCTSkip("Set WHISPERDROP_VERIFY_MICROPHONE=1 to verify the local microphone")
        }
        try XCTSkipUnless(MicCapture.isAuthorized, "Microphone access is not granted to the test runner")
        let capture = MicCapture()
        defer { capture.stop() }
        for _ in 0..<3 {
            let delivered = DispatchSemaphore(value: 0)
            capture.onSamples = { samples in
                if !samples.isEmpty { delivered.signal() }
            }
            try capture.start()
            XCTAssertEqual(delivered.wait(timeout: .now() + 5), .success)
            capture.stop()
        }
    }

    /// Opt-in, needs a connected Bluetooth headset that is the default input, and a built-in microphone.
    /// The headset must keep its playback sample rate while a capture object exists, runs and stops.
    func testBluetoothHeadsetKeepsItsPlaybackFormatAroundCapture() throws {
        guard ProcessInfo.processInfo.environment["WHISPERDROP_VERIFY_MICROPHONE"] == "1" else {
            throw XCTSkip("Set WHISPERDROP_VERIFY_MICROPHONE=1 to verify the local microphone")
        }
        try XCTSkipUnless(MicCapture.isAuthorized, "Microphone access is not granted to the test runner")
        let defaultInput = try XCTUnwrap(AudioInputDevices.defaultInput())
        try XCTSkipUnless(AudioInputDevices.isBluetooth(defaultInput), "The default input is not a Bluetooth headset")
        let builtIn = try XCTUnwrap(AudioInputDevices.builtInInput(), "No built-in microphone")
        XCTAssertEqual(AudioInputDevices.preferredInput(), builtIn)
        let headset = try XCTUnwrap(bluetoothOutput(), "No Bluetooth output device")
        let playbackRate = nominalSampleRate(headset)
        XCTAssertGreaterThan(playbackRate, 16_000, "The headset is already in its speaking mode")

        let capture = MicCapture()
        defer { capture.stop() }
        Thread.sleep(forTimeInterval: 1.5)
        XCTAssertEqual(nominalSampleRate(headset), playbackRate, "idle capture object")
        for _ in 0..<2 {
            let delivered = DispatchSemaphore(value: 0)
            capture.onSamples = { samples in
                if !samples.isEmpty { delivered.signal() }
            }
            try capture.start()
            XCTAssertEqual(delivered.wait(timeout: .now() + 5), .success)
            Thread.sleep(forTimeInterval: 1.5)
            XCTAssertEqual(nominalSampleRate(headset), playbackRate, "while capturing")
            capture.stop()
            Thread.sleep(forTimeInterval: 1)
            XCTAssertEqual(nominalSampleRate(headset), playbackRate, "after stopping")
        }
    }

    private func bluetoothOutput() -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain
        )
        let system = AudioObjectID(kAudioObjectSystemObject)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr else { return nil }
        var devices = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &devices) == noErr else { return nil }
        return devices.first { device in
            var streams = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyStreams, mScope: kAudioObjectPropertyScopeOutput, mElement: kAudioObjectPropertyElementMain
            )
            var streamsSize: UInt32 = 0
            AudioObjectGetPropertyDataSize(device, &streams, 0, nil, &streamsSize)
            return streamsSize > 0 && AudioInputDevices.isBluetooth(device)
        }
    }

    private func nominalSampleRate(_ device: AudioDeviceID) -> Double {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain
        )
        var rate: Float64 = 0
        var size = UInt32(MemoryLayout<Float64>.size)
        AudioObjectGetPropertyData(device, &address, 0, nil, &size, &rate)
        return rate
    }

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
