import AVFoundation

/// Saved note audio is AAC in an M4A file, about one fifth the size of the PCM it was recorded as.
/// Recording still appends PCM to a CAF, which stays readable after a crash. The CAF is converted once it is closed.
enum AudioCompressor {
    static let fileExtension = "m4a"
    /// Bits per second, the most Apple's encoder accepts for 16 kHz mono: about 22 MB per hour.
    /// At 32,000 a quiet recording transcribed slightly worse than its PCM; see docs/audio-storage-and-cleanup.md.
    static let bitRate = 48_000

    /// Replaces `recording` with an M4A beside it. The recording is discarded only after the copy holds every frame.
    @discardableResult
    static func replace(_ recording: URL, discard: (URL) throws -> Void = { try FileManager.default.removeItem(at: $0) }) throws -> URL {
        let fm = FileManager.default
        let folder = recording.deletingLastPathComponent()
        let destination = recording.deletingPathExtension().appendingPathExtension(fileExtension)
        let frames = try AVAudioFile(forReading: recording).length
        // An M4A with this name can only come from an earlier conversion of the same recording.
        if (try? AVAudioFile(forReading: destination).length) != frames {
            for stale in (try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [] where stale.lastPathComponent.hasPrefix(temporaryPrefix) {
                try? fm.removeItem(at: stale)
            }
            let temporary = folder.appendingPathComponent("\(temporaryPrefix)\(UUID().uuidString).\(fileExtension)")
            defer { try? fm.removeItem(at: temporary) }
            try encode(recording, to: temporary)
            guard frames > 0, try AVAudioFile(forReading: temporary).length == frames else {
                throw AppFailure("The compressed recording could not be verified. The original was kept.")
            }
            if fm.fileExists(atPath: destination.path) { try fm.removeItem(at: destination) }
            try fm.moveItem(at: temporary, to: destination)
        }
        try discard(recording)
        return destination
    }

    /// An unfinished copy carries this prefix until it is verified. One left by a quit is removed by the next conversion.
    private static let temporaryPrefix = ".compressing-"

    private static func encode(_ source: URL, to destination: URL) throws {
        let input = try AVAudioFile(forReading: source, commonFormat: .pcmFormatInt16, interleaved: true)
        let format = input.processingFormat
        let output = try AVAudioFile(forWriting: destination, settings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: format.sampleRate,
            AVNumberOfChannelsKey: format.channelCount, AVEncoderBitRateKey: bitRate
        ], commonFormat: .pcmFormatInt16, interleaved: true)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1 << 16) else {
            throw AppFailure("The recording could not be read for compression.")
        }
        while input.framePosition < input.length {
            try input.read(into: buffer)
            guard buffer.frameLength > 0 else { break }
            try output.write(from: buffer)
        }
    }
}
