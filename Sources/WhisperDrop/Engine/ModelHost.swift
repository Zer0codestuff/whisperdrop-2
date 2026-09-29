import Foundation
import WhisperDropCore

/// Contract file. Keeps one whisper-server child process loaded with the live model,
/// serializes requests and unloads it after the idle policy expires.
@MainActor
final class ModelHost: ObservableObject {
    enum State: Equatable {
        case unloaded, loading, ready, busy
        case failed(String)
        var label: String {
            switch self {
            case .unloaded: "Model unloaded"
            case .loading: "Loading model"
            case .ready: "Model ready"
            case .busy: "Transcribing"
            case .failed(let message): message
            }
        }
    }
    @Published private(set) var state: State = .unloaded
    /// Id of the model currently loaded, if any.
    @Published private(set) var loadedModel: String?
    /// Idle policy; changes take effect immediately.
    var residency: ModelResidency = .tenMinutes
    /// When true the model is never unloaded for idleness.
    var keepReady = false

    /// - Parameters:
    ///   - tool: locates bundled executables by name (e.g. "whisper-server").
    ///   - modelFile: returns the local file of an installed model, throwing a user-facing error if it is not downloaded.
    init(tool: @escaping (String) throws -> URL, modelFile: @escaping (TranscriptionModel) throws -> URL) {}

    /// Starts loading `model` in the background if it is not already loaded. Never throws; failures go to `state`.
    func prewarm(_ model: TranscriptionModel) {}
    /// Loads `model` if needed and waits until the server accepts requests.
    func ensureReady(_ model: TranscriptionModel) async throws {}
    /// Transcribes 16 kHz mono samples. Requests run one at a time in FIFO order. Resets the idle timer.
    /// `shortClip` (dictation) shrinks the encoder window with `audio_ctx` for clips up to 25 s, which cuts latency about 4x.
    func transcribe(_ samples: [Float], model: TranscriptionModel, language: String, prompt: String? = nil,
                    offset: Double = 0, speaker: Speaker? = nil, shortClip: Bool = false) async throws -> ServerTranscription {
        ServerTranscription(segments: [], language: nil)
    }
    /// Prevents idle unloading until the returned lease is released (used while a note is recording).
    func acquireLease() -> UUID { UUID() }
    func releaseLease(_ lease: UUID) {}
    /// Stops the server process and frees its memory.
    func unload() {}
    /// Call from applicationWillTerminate; must kill the child synchronously.
    func shutdown() {}
}
