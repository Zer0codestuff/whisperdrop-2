import AVFoundation
import CoreAudio
import Foundation
import os

/// Copies one PCM callback into a preallocated slot.
///
/// The real-time thread only claims a slot, copies bytes, and signals. Conversion runs on `worker`.
final class PCMSlotQueue: @unchecked Sendable {
    struct Packet {
        var format: AudioStreamBasicDescription
        var frames: Int
        var bufferCount: Int
        var sizes: (UInt32, UInt32, UInt32, UInt32, UInt32, UInt32, UInt32, UInt32)
        var payload: UnsafeRawPointer
    }

    let payloadCapacity: Int

    private struct SlotHeader {
        var sampleRate: Float64 = 0
        var formatID: UInt32 = 0
        var formatFlags: UInt32 = 0
        var bytesPerPacket: UInt32 = 0
        var framesPerPacket: UInt32 = 0
        var bytesPerFrame: UInt32 = 0
        var channels: UInt32 = 0
        var bits: UInt32 = 0
        var frames: UInt32 = 0
        var bufferCount: UInt32 = 0
        var sizes: (UInt32, UInt32, UInt32, UInt32, UInt32, UInt32, UInt32, UInt32) = (0, 0, 0, 0, 0, 0, 0, 0)
    }

    private static let empty: Int32 = 0
    private static let filling: Int32 = 1
    private static let ready: Int32 = 2
    private static let draining: Int32 = 3
    private static let slotCount = 4
    private static let headerSize = MemoryLayout<SlotHeader>.stride

    private let slotStride: Int
    private let storage: UnsafeMutableRawPointer
    private let phases: UnsafeMutablePointer<Int32>
    private let lock = OSAllocatedUnfairLock()
    private let semaphore = DispatchSemaphore(value: 0)
    private let worker: DispatchQueue
    private let workerKey = DispatchSpecificKey<Int>()
    private let onPacket: (Packet) -> Void
    private var workerRunning = false
    private var stopped = true

    init(payloadCapacity: Int, label: String, onPacket: @escaping (Packet) -> Void) {
        self.payloadCapacity = payloadCapacity
        self.onPacket = onPacket
        let rawStride = Self.headerSize + payloadCapacity
        slotStride = (rawStride + 15) & ~15
        storage = .allocate(byteCount: slotStride * Self.slotCount, alignment: 16)
        phases = .allocate(capacity: Self.slotCount)
        phases.initialize(repeating: Self.empty, count: Self.slotCount)
        worker = DispatchQueue(label: label)
        worker.setSpecific(key: workerKey, value: 1)
    }

    deinit {
        stop()
        phases.deinitialize(count: Self.slotCount)
        phases.deallocate()
        storage.deallocate()
    }

    func start() {
        let launch = lock.withLockUnchecked { () -> Bool in
            stopped = false
            if workerRunning { return false }
            for index in 0..<Self.slotCount {
                phases[index] = Self.empty
            }
            workerRunning = true
            return true
        }
        guard launch else { return }
        let semaphore = semaphore
        worker.async { [weak self] in
            while true {
                semaphore.wait()
                guard let self else { return }
                if !self.drainAll() { return }
            }
        }
    }

    /// Drains packets already copied, then lets the worker exit. Safe to call from the worker.
    func stop() {
        let join = lock.withLockUnchecked { () -> Bool in
            let wasRunning = workerRunning
            stopped = true
            workerRunning = false
            return wasRunning
        }
        guard join else { return }
        semaphore.signal()
        if DispatchQueue.getSpecific(key: workerKey) == 1 { return }
        worker.sync {}
    }

    /// Microphone tap. Copies `frameLength` bytes per buffer, not the allocated capacity.
    func publish(_ buffer: AVAudioPCMBuffer) {
        let frames = Int(buffer.frameLength)
        guard frames > 0 else { return }
        let format = buffer.format.streamDescription.pointee
        let bytesPerBuffer = frames * max(Int(format.mBytesPerFrame), 1)
        publish(format: format, frames: frames, list: buffer.audioBufferList, bytesPerBuffer: bytesPerBuffer)
    }

    /// HAL input callback. `mDataByteSize` is the valid byte count.
    func publish(format: AudioStreamBasicDescription, list: UnsafePointer<AudioBufferList>) {
        let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: list))
        guard let first = buffers.first, first.mDataByteSize > 0 else { return }
        let frames = frameCount(format: format, bytes: Int(first.mDataByteSize))
        guard frames > 0 else { return }
        publish(format: format, frames: frames, list: list, bytesPerBuffer: nil)
    }

    private func publish(
        format: AudioStreamBasicDescription,
        frames: Int,
        list: UnsafePointer<AudioBufferList>,
        bytesPerBuffer: Int?
    ) {
        let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: list))
        let bufferCount = buffers.count
        guard bufferCount > 0, bufferCount <= 8 else { return }

        let claimed = lock.withLockIfAvailableUnchecked { () -> Int in
            if stopped { return -1 }
            for index in 0..<Self.slotCount where phases[index] == Self.empty {
                phases[index] = Self.filling
                return index
            }
            return -1
        }
        guard let index = claimed, index >= 0 else { return }

        var accepted = false
        defer {
            if !accepted {
                lock.withLockUnchecked { phases[index] = Self.empty }
            }
        }

        let slot = storage.advanced(by: index * slotStride)
        let payload = slot.advanced(by: Self.headerSize)
        var sizes: (UInt32, UInt32, UInt32, UInt32, UInt32, UInt32, UInt32, UInt32) = (0, 0, 0, 0, 0, 0, 0, 0)
        var offset = 0
        var copied = false
        for bufferIndex in 0..<bufferCount {
            let audioBuffer = buffers[bufferIndex]
            let available = Int(audioBuffer.mDataByteSize)
            let wanted = bytesPerBuffer.map { min($0, available) } ?? available
            // A disabled stream has a null mData and a still-valid byte count. Store nothing for it.
            let stored: Int
            if wanted > 0, let source = audioBuffer.mData {
                guard offset + wanted <= payloadCapacity else { return }
                payload.advanced(by: offset).copyMemory(from: source, byteCount: wanted)
                stored = wanted
                copied = true
                offset += wanted
            } else {
                stored = 0
            }
            withUnsafeMutableBytes(of: &sizes) { raw in
                raw.bindMemory(to: UInt32.self)[bufferIndex] = UInt32(stored)
            }
        }
        guard copied else { return }

        var header = SlotHeader()
        header.sampleRate = format.mSampleRate
        header.formatID = format.mFormatID
        header.formatFlags = format.mFormatFlags
        header.bytesPerPacket = format.mBytesPerPacket
        header.framesPerPacket = format.mFramesPerPacket
        header.bytesPerFrame = format.mBytesPerFrame
        header.channels = format.mChannelsPerFrame
        header.bits = format.mBitsPerChannel
        header.frames = UInt32(frames)
        header.bufferCount = UInt32(bufferCount)
        header.sizes = sizes
        slot.storeBytes(of: header, as: SlotHeader.self)

        accepted = true
        lock.withLockUnchecked { phases[index] = Self.ready }
        semaphore.signal()
    }

    private func drainAll() -> Bool {
        while true {
            let index = lock.withLockUnchecked { () -> Int in
                for slot in 0..<Self.slotCount where phases[slot] == Self.ready {
                    phases[slot] = Self.draining
                    return slot
                }
                return stopped ? -2 : -1
            }
            if index == -2 { return false }
            if index < 0 { return true }
            deliver(index)
            lock.withLockUnchecked { phases[index] = Self.empty }
        }
    }

    private func deliver(_ index: Int) {
        let slot = storage.advanced(by: index * slotStride)
        let header = slot.load(as: SlotHeader.self)
        let payload = slot.advanced(by: Self.headerSize)
        guard header.frames > 0 else { return }
        var format = AudioStreamBasicDescription()
        format.mSampleRate = header.sampleRate
        format.mFormatID = header.formatID
        format.mFormatFlags = header.formatFlags
        format.mBytesPerPacket = header.bytesPerPacket
        format.mFramesPerPacket = header.framesPerPacket
        format.mBytesPerFrame = header.bytesPerFrame
        format.mChannelsPerFrame = header.channels
        format.mBitsPerChannel = header.bits
        onPacket(Packet(
            format: format,
            frames: Int(header.frames),
            bufferCount: Int(header.bufferCount),
            sizes: header.sizes,
            payload: payload
        ))
    }

    private func frameCount(format: AudioStreamBasicDescription, bytes: Int) -> Int {
        let bytesPerFrame = Int(format.mBytesPerFrame)
        if bytesPerFrame > 0 { return bytes / bytesPerFrame }
        let bytesPerSample = max(Int(format.mBitsPerChannel) / 8, 1)
        let channels = max(Int(format.mChannelsPerFrame), 1)
        let nonInterleaved = (format.mFormatFlags & kAudioFormatFlagIsNonInterleaved) != 0
        if nonInterleaved { return bytes / bytesPerSample }
        return bytes / (bytesPerSample * channels)
    }
}

enum PCMBuffers {
    /// Copies a slot into an `AVAudioPCMBuffer` the converter can own. The packet pointer is only valid during the callback.
    static func make(_ packet: PCMSlotQueue.Packet) -> AVAudioPCMBuffer? {
        var formatDescription = packet.format
        guard packet.frames > 0,
              let format = AVAudioFormat(streamDescription: &formatDescription),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(packet.frames)) else {
            return nil
        }
        buffer.frameLength = AVAudioFrameCount(packet.frames)
        let destination = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
        var offset = 0
        let count = min(packet.bufferCount, destination.count, 8)
        for index in 0..<count {
            let size = size(packet.sizes, index)
            defer { offset += size }
            guard size > 0, let pointer = destination[index].mData else { continue }
            let byteCount = min(size, Int(destination[index].mDataByteSize))
            guard byteCount > 0 else { continue }
            pointer.copyMemory(from: packet.payload.advanced(by: offset), byteCount: byteCount)
        }
        return buffer
    }

    private static func size(
        _ sizes: (UInt32, UInt32, UInt32, UInt32, UInt32, UInt32, UInt32, UInt32),
        _ index: Int
    ) -> Int {
        withUnsafeBytes(of: sizes) { raw in
            Int(raw.bindMemory(to: UInt32.self)[index])
        }
    }
}
