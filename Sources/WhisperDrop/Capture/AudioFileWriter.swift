import Foundation

/// Contract file. Appends 16 kHz mono Float samples to a file incrementally so a crash keeps what was recorded.
final class AudioFileWriter: @unchecked Sendable {
    let url: URL
    /// Creates or truncates the file at `url` (a .caf or .wav container; implementation choice).
    init(url: URL) throws { self.url = url }
    /// Thread safe.
    func append(_ samples: [Float]) {}
    /// Finalizes headers. Safe to call more than once.
    func close() {}
}
