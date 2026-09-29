import Foundation
import WhisperDropCore

/// Contract file. Records a meeting or lecture and transcribes it incrementally.
@MainActor
final class NoteRecorder: ObservableObject {
    enum State: Equatable { case idle, starting, recording, finishing, failed(String) }
    @Published private(set) var state: State = .idle
    @Published private(set) var sources: NoteSources = .both
    /// Seconds since the recording started.
    @Published private(set) var elapsed: Double = 0
    /// Live merged transcript so far.
    @Published private(set) var segments: [TranscriptSegment] = []
    @Published private(set) var micLevel: Float = 0
    @Published private(set) var systemLevel: Float = 0
    /// Chunks recorded but not transcribed yet.
    @Published private(set) var pendingChunks = 0
    @Published var title = ""

    /// - Parameters:
    ///   - folder: where recordings are written (one subfolder per note).
    ///   - onFinish: receives the completed job (kind `.note`, status `.completed`) to add to the library.
    init(settings: AppSettings, host: ModelHost, folder: URL, onFinish: @escaping (TranscriptionJob) -> Void) {}
    func start(_ sources: NoteSources) {}
    /// Stops capture, transcribes remaining audio, then calls `onFinish`.
    func stop() {}
    /// Stops and discards the recording.
    func discard() {}
}
