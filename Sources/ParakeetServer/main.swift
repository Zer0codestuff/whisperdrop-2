import Foundation
import MLX
import ParakeetMLX
import WhisperDropCore

// A loopback server with the whisper-server interface that ModelHost already speaks:
// GET /health and a multipart POST to the secret inference path, answered with `verbose_json`.
// usage: parakeet-server --model DIR --port N --inference-path /secret [--host 127.0.0.1] [--cache-mb N]

struct Options {
    var model = ""
    var host = "127.0.0.1"
    var port: UInt16 = 0
    var inferencePath = "/inference"
    var cacheMB = 512

    init(_ arguments: [String]) {
        var index = 1
        func value() -> String? {
            index += 1
            return index < arguments.count ? arguments[index] : nil
        }
        while index < arguments.count {
            switch arguments[index] {
            case "--model", "-m": model = value() ?? ""
            case "--host": host = value() ?? host
            case "--port": port = UInt16(value() ?? "") ?? 0
            case "--inference-path": inferencePath = value() ?? inferencePath
            case "--cache-mb": cacheMB = Int(value() ?? "") ?? cacheMB
            default: break
            }
            index += 1
        }
    }
}

func log(_ text: String) {
    FileHandle.standardError.write(Data((text + "\n").utf8))
}

let options = Options(CommandLine.arguments)
guard !options.model.isEmpty, options.port > 0 else {
    log("usage: parakeet-server --model DIR --port N --inference-path /secret")
    exit(2)
}
guard options.host == "127.0.0.1" || options.host == "localhost" else {
    log("parakeet-server only listens on the loopback interface.")
    exit(2)
}

let started = Date()
let model: ParakeetModel
do {
    model = try ParakeetModel.fromDirectory(URL(fileURLWithPath: options.model))
} catch {
    log("Could not load the Parakeet model: \(error.localizedDescription)")
    exit(1)
}
Memory.cacheLimit = options.cacheMB * 1024 * 1024
// The first decode compiles Metal kernels. Pay it before reporting healthy.
_ = model.alignedTranscription(MLXArray.zeros([whisperSampleRate / 2]))
log(String(format: "parakeet-server: model ready in %.2f s", Date().timeIntervalSince(started)))

/// Model calls stay on one thread. MLX graphs are not shared across threads here.
let inferenceQueue = DispatchQueue(label: "parakeet.inference")

@Sendable func transcribe(_ wav: Data, language: String?) throws -> Data {
    guard let decoded = WAVDecoder.pcm16(wav) else { throw ServerError.badRequest("Send 16-bit PCM WAV audio.") }
    guard decoded.sampleRate == whisperSampleRate else { throw ServerError.badRequest("Send 16 kHz audio.") }
    let samples = decoded.samples
    let duration = Double(samples.count) / Double(whisperSampleRate)
    let reported = language.flatMap { $0.isEmpty || $0 == "auto" ? nil : $0 }
    var sentences: [TimedSentence] = []
    for window in LongAudioPlan.windows(samples) {
        let slice = samples[window]
        // The same silence test as the reference runtime: nothing to decode.
        guard (slice.map(abs).max() ?? 0) >= 1e-4 else { continue }
        let offset = Double(window.lowerBound) / Double(whisperSampleRate)
        let result = model.alignedTranscription(MLXArray(Array(slice)))
        for sentence in result.sentences {
            let pieces = sentence.tokens.map { TimedPiece(text: $0.text, start: $0.start + offset, end: $0.end + offset) }
            sentences.append(TimedSentence(text: sentence.text, pieces: pieces))
        }
    }
    Memory.clearCache()
    return try VerboseJSON.encode(sentences, language: reported, duration: duration)
}

enum ServerError: Error {
    case badRequest(String)
}

let server = LoopbackHTTPServer(port: options.port) { request in
    switch (request.method, request.path) {
    case ("GET", "/health"):
        return .json(200, #"{"status":"ok"}"#)
    case ("POST", options.inferencePath):
        guard let form = request.multipart(), let file = form.files["file"] else {
            return .error(400, "Send the audio as the multipart field named file.")
        }
        return inferenceQueue.sync {
            do {
                return HTTPResponse(status: 200, body: try transcribe(file, language: form.fields["language"]))
            } catch ServerError.badRequest(let message) {
                return .error(400, message)
            } catch {
                return .error(500, error.localizedDescription)
            }
        }
    default:
        return .error(404, "Not found.")
    }
}
do {
    try server.start()
} catch {
    log("parakeet-server could not listen on port \(options.port): \(error.localizedDescription)")
    exit(1)
}
dispatchMain()
