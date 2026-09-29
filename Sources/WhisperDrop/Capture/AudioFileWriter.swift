import AudioToolbox
import Foundation

/// Contract file. Appends 16 kHz mono Float samples to a file incrementally so a crash keeps what was recorded.
final class AudioFileWriter: @unchecked Sendable {
    let url: URL

    private let queue = DispatchQueue(label: "whisperdrop.audio-file")
    private let queueKey = DispatchSpecificKey<UInt8>()
    private var handle: FileHandle?
    private var closed = false
    private var failed = false

    /// Byte offset of the data chunk's size field: 8 file header + 12 desc header + 32 desc + 4 'data'.
    private static let chunkSizeOffset: UInt64 = 56
    /// First byte of the data chunk payload (edit count, then PCM).
    private static let chunkPayloadOffset: UInt64 = 64
    private static let sampleRate: Float64 = 16_000

    /// Creates or truncates the file at `url` (a .caf or .wav container; implementation choice).
    init(url: URL) throws {
        self.url = url
        let parent = url.deletingLastPathComponent()
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: parent.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw CaptureError.fileFailed("The folder for the recording does not exist.")
        }
        guard FileManager.default.createFile(atPath: url.path, contents: Data()) else {
            throw CaptureError.fileFailed("The recording file could not be created.")
        }
        let handle = try FileHandle(forWritingTo: url)
        do {
            try handle.write(contentsOf: Self.fileHeader())
            try handle.synchronize()
        } catch {
            try? handle.close()
            throw CaptureError.fileFailed("The recording file could not be created.")
        }
        self.handle = handle
        queue.setSpecific(key: queueKey, value: 1)
    }

    /// Thread safe.
    func append(_ samples: [Float]) {
        onQueue {
            guard !closed, !failed, !samples.isEmpty, let handle else { return }
            do {
                try handle.write(contentsOf: Self.pcm16(samples))
                try handle.synchronize()
            } catch {
                failed = true
            }
        }
    }

    /// Finalizes headers. Safe to call more than once.
    func close() {
        onQueue {
            guard !closed, let handle else { return }
            closed = true
            do {
                let end = try handle.seekToEnd()
                if end >= Self.chunkPayloadOffset {
                    // CAFFile.h: a negative data-chunk size means "read to EOF", so a crash before
                    // this patch still leaves a defined file. The real size includes the edit count.
                    let chunkSize = Int64(end) - Int64(Self.chunkPayloadOffset)
                    try handle.seek(toOffset: Self.chunkSizeOffset)
                    var size = Data()
                    size.appendBigEndian(chunkSize)
                    try handle.write(contentsOf: size)
                    try handle.synchronize()
                }
                try handle.close()
            } catch {
                try? handle.close()
            }
            self.handle = nil
        }
    }

    private func onQueue(_ body: () -> Void) {
        if DispatchQueue.getSpecific(key: queueKey) == 1 {
            body()
        } else {
            queue.sync(execute: body)
        }
    }

    private static func pcm16(_ samples: [Float]) -> Data {
        var data = Data(count: samples.count * MemoryLayout<Int16>.size)
        data.withUnsafeMutableBytes { raw in
            let destination = raw.bindMemory(to: Int16.self)
            for index in samples.indices {
                let clamped = max(-1 as Float, min(1, samples[index]))
                destination[index] = Int16((clamped * 32_767).rounded())
            }
        }
        return data
    }

    /// 16 kHz mono signed 16-bit little-endian CAF. The data chunk size is -1 until `close()`.
    private static func fileHeader() -> Data {
        var data = Data()
        data.appendBigEndian(UInt32(kCAF_FileType))
        data.appendBigEndian(UInt16(kCAF_FileVersion_Initial))
        data.appendBigEndian(UInt16(0))
        data.appendBigEndian(UInt32(kCAF_StreamDescriptionChunkID))
        data.appendBigEndian(Int64(32))
        data.appendBigEndian(sampleRate)
        data.appendBigEndian(UInt32(kAudioFormatLinearPCM))
        // CAFFile.h defines little-endian PCM as (1 << 1). The Swift overlay does not import that constant.
        data.appendBigEndian(UInt32(1 << 1))
        data.appendBigEndian(UInt32(MemoryLayout<Int16>.size))
        data.appendBigEndian(UInt32(1))
        data.appendBigEndian(UInt32(1))
        data.appendBigEndian(UInt32(16))
        data.appendBigEndian(UInt32(kCAF_AudioDataChunkID))
        data.appendBigEndian(Int64(-1))
        data.appendBigEndian(UInt32(0))
        return data
    }
}
