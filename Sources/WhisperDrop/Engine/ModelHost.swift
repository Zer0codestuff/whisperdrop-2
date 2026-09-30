import Foundation
import Darwin
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
    @Published private(set) var state: State = .unloaded {
        didSet {
            #if DEBUG
            if oldValue != state { stateTrace.append(state) }
            #endif
        }
    }
    /// Id of the model currently loaded, if any.
    @Published private(set) var loadedModel: String?
    /// Idle policy; changes take effect immediately.
    var residency: ModelResidency = .tenMinutes {
        didSet { reevaluateIdle(resetClock: false) }
    }
    /// When true the model is never unloaded for idleness.
    var keepReady = false {
        didSet { reevaluateIdle(resetClock: false) }
    }

    #if DEBUG
    /// State changes since launch, for tests.
    private(set) var stateTrace: [State] = []
    #endif

    /// Encoder frames for a short clip: min(1500, ceil to a multiple of 64 of duration * 50 + 160).
    static func audioContext(duration: Double) -> Int {
        let frames = duration * 50 + 160
        let steps = Int(((frames - 1e-6) / 64).rounded(.up))
        return min(1500, max(0, steps) * 64)
    }

    static var pidFileURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("WhisperDrop 2", isDirectory: true)
            .appendingPathComponent("whisper-server.pid")
    }

    var serverProcessIdentifier: pid_t? {
        guard let process, process.isRunning else { return nil }
        return process.processIdentifier
    }

    private let tool: (String) throws -> URL
    @Published private(set) var speechCheckWarning: String?
    private(set) var lastAudioGain: Float = 1
    private(set) var lastPreprocessingSeconds: Double = 0
    private(set) var lastRepetitionRetry = false
    private let modelFile: (TranscriptionModel) throws -> URL
    private let processFile: URL
    private let preserveWords: Bool
    private let session: URLSession
    private let healthSession: URLSession
    private let stderrTail = StderrTail()
    private var chain: Task<Void, Never>
    private var process: Process?
    private var errorPipe: Pipe?
    private var port: UInt16?
    private var inferencePath: String?
    private var leases: Set<UUID> = []
    private var pending = 0
    private var idleTask: Task<Void, Never>?
    private var idleGeneration: UInt = 0
    private var becameIdleAt: Date?
    private var intentionalStop = false
    private var lifetime = 0
    private var isShutDown = false
    private nonisolated(unsafe) var livePID: pid_t = 0

    private static let pidMarker = "WhisperDrop2-whisper-server"
    private static let loadTimeout: TimeInterval = 90
    private static let healthPause: UInt64 = 100_000_000

    /// - Parameters:
    ///   - tool: locates bundled executables by name (e.g. "whisper-server").
    ///   - modelFile: returns the local file of an installed model, throwing a user-facing error if it is not downloaded.
    init(tool: @escaping (String) throws -> URL, modelFile: @escaping (TranscriptionModel) throws -> URL,
         processFile: URL? = nil, preserveWords: Bool = true) {
        self.tool = tool
        self.modelFile = modelFile
        self.processFile = processFile ?? Self.pidFileURL
        self.preserveWords = preserveWords
        session = Self.makeSession(requestTimeout: 120, resourceTimeout: 120)
        healthSession = Self.makeSession(requestTimeout: 2, resourceTimeout: 2)
        chain = Task {}
        reapStaleServer()
    }

    deinit {
        let pid = livePID
        guard pid > 0, Self.commandName(pid) == "whisper-server" else { return }
        kill(pid, SIGKILL)
    }

    /// Starts loading `model` in the background if it is not already loaded. Never throws; failures go to `state`.
    func prewarm(_ model: TranscriptionModel) {
        Task { @MainActor in
            guard !self.isShutDown else { return }
            do {
                try await self.ensureReady(model)
                self.armIdleTimer()
            } catch {
                self.recordPrewarmFailure(error)
            }
        }
    }

    /// Loads `model` if needed and waits until the server accepts requests.
    func ensureReady(_ model: TranscriptionModel) async throws {
        let operation = schedule {
            try await self.loadIfNeeded(model)
        }
        try await withTaskCancellationHandler {
            try await operation.value
        } onCancel: {
            // The load keeps running so a cancelled waiter does not kill a model that is mid-compile.
        }
    }

    /// Transcribes 16 kHz mono samples. Requests run one at a time in FIFO order. Resets the idle timer.
    /// `shortClip` (dictation) shrinks the encoder window with `audio_ctx` for clips up to 25 s, which cuts latency about 4x.
    func transcribe(_ samples: [Float], model: TranscriptionModel, language: String, prompt: String? = nil,
                    offset: Double = 0, speaker: Speaker? = nil, shortClip: Bool = false, checkSilence: Bool = true,
                    boostQuietAudio: Bool = false) async throws -> ServerTranscription {
        if isShutDown { throw AppFailure("WhisperDrop is quitting.") }
        pending += 1
        let cancel = RequestCancel()
        let operation = schedule(finally: {
            self.pending -= 1
            self.armIdleTimer()
        }) {
            try await self.perform(samples: samples, model: model, language: language, prompt: prompt,
                                   offset: offset, speaker: speaker, shortClip: shortClip, checkSilence: checkSilence,
                                   boostQuietAudio: boostQuietAudio, cancel: cancel)
        }
        return try await withTaskCancellationHandler {
            try await operation.value
        } onCancel: {
            cancel.cancel()
        }
    }

    /// Prevents idle unloading until the returned lease is released (used while a note is recording).
    func acquireLease() -> UUID {
        let id = UUID()
        leases.insert(id)
        reevaluateIdle(resetClock: false)
        return id
    }

    func releaseLease(_ lease: UUID) {
        guard leases.remove(lease) != nil else { return }
        if leases.isEmpty { becameIdleAt = Date() }
        reevaluateIdle(resetClock: false)
    }

    /// Stops the server process and frees its memory.
    func unload() {
        guard !isShutDown else {
            stopServer(intentional: true)
            state = .unloaded
            return
        }
        idleTask?.cancel()
        idleTask = nil
        becameIdleAt = nil
        stopServer(intentional: true)
        state = .unloaded
    }

    /// Call from applicationWillTerminate; must kill the child synchronously.
    func shutdown() {
        isShutDown = true
        idleTask?.cancel()
        idleTask = nil
        becameIdleAt = nil
        stopServer(intentional: true)
        state = .unloaded
    }

    // MARK: - Queue

    /// Runs work after every earlier request. A failure completes the link instead of cancelling the ones behind it.
    private func schedule<T: Sendable>(finally: (@MainActor () -> Void)? = nil,
                                       _ work: @escaping @MainActor () async throws -> T) -> Task<T, Error> {
        let predecessor = chain
        let operation = Task { @MainActor () throws -> T in
            defer { finally?() }
            await predecessor.value
            try Task.checkCancellation()
            return try await work()
        }
        chain = Task { _ = await operation.result }
        return operation
    }

    // MARK: - Load

    private func loadIfNeeded(_ model: TranscriptionModel) async throws {
        if isShutDown { throw CancellationError() }
        if processIsRunning, loadedModel == model.id, port != nil, inferencePath != nil { return }
        let file = try modelFile(model)
        guard FileManager.default.isReadableFile(atPath: file.path) else {
            throw AppFailure("The \(model.name) speech model is not on this Mac. Download it in WhisperDrop, then try again.")
        }
        if isShutDown { throw CancellationError() }
        if process != nil {
            stopServer(intentional: true)
            state = .unloaded
        }
        try await startServer(model: model, file: file)
    }

    private func startServer(model: TranscriptionModel, file: URL) async throws {
        if isShutDown { throw CancellationError() }
        let executable = try tool("whisper-server")
        let reserved = try Self.reserveLoopbackPort()
        let secret = "/" + UUID().uuidString + "/inference"
        let launched = Process()
        launched.executableURL = executable
        launched.arguments = Self.arguments(modelPath: file.path, port: reserved, inferencePath: secret)
        launched.standardInput = FileHandle.nullDevice
        launched.standardOutput = FileHandle.nullDevice
        let pipe = Pipe()
        launched.standardError = pipe
        launched.environment = Self.launchEnvironment(executable: executable)
        stderrTail.reset()
        errorPipe = pipe
        capture(pipe)
        intentionalStop = false
        let life = lifetime
        state = .loading
        launched.terminationHandler = { [weak self] exited in
            let pid = exited.processIdentifier
            Task { @MainActor in
                self?.handleExit(pid: pid)
            }
        }
        do {
            try launched.run()
        } catch {
            launched.terminationHandler = nil
            detachProcess()
            let message = "The speech model could not start. \(Self.userFacing(error))"
            state = .failed(message)
            throw AppFailure(message)
        }
        process = launched
        port = reserved
        inferencePath = secret
        writePIDFile(launched.processIdentifier)
        do {
            try await waitUntilHealthy(port: reserved, life: life)
        } catch {
            if intentionalStop || lifetime != life || isShutDown {
                throw error
            }
            if case .failed = state { throw error }
            let message = Self.userFacing(error)
            state = .failed(message)
            throw error
        }
        guard processIsRunning, lifetime == life, !isShutDown else {
            throw CancellationError()
        }
        loadedModel = model.id
        state = .ready
        armIdleTimer()
    }

    /// Stays in `.loading` for the whole boot, including the one-time Metal shader compile (~16 s).
    /// Callers still see `.loading` after 3 seconds. Only a dead process or the 90 second cap fails the load.
    private func waitUntilHealthy(port: UInt16, life: Int) async throws {
        let deadline = Date().addingTimeInterval(Self.loadTimeout)
        while Date() < deadline {
            if isShutDown || intentionalStop || lifetime != life {
                throw CancellationError()
            }
            if !processIsRunning {
                if isShutDown || intentionalStop || lifetime != life {
                    throw CancellationError()
                }
                let message = loadFailureMessage()
                detachProcess()
                state = .failed(message)
                throw AppFailure(message)
            }
            if await healthIsReady(port: port) {
                return
            }
            try await Task.sleep(nanoseconds: Self.healthPause)
        }
        let message = "The speech model took too long to load. Try again in a moment."
        stopServer(intentional: true)
        state = .failed(message)
        throw AppFailure(message)
    }

    private func healthIsReady(port: UInt16) async -> Bool {
        guard let url = Self.endpoint(port: port, path: "/health") else { return false }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 2
        request.cachePolicy = .reloadIgnoringLocalCacheData
        do {
            let (data, response) = try await healthSession.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return false }
            let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            return object?["status"] as? String == "ok"
        } catch {
            // Connection refused is the normal state until whisper_init returns and the socket starts listening.
            return false
        }
    }

    private func recordPrewarmFailure(_ error: Error) {
        if error is CancellationError { return }
        switch state {
        case .ready, .busy, .failed:
            return
        case .unloaded, .loading:
            state = .failed(Self.userFacing(error))
        }
    }

    // MARK: - Transcription

    private func perform(samples: [Float], model: TranscriptionModel, language: String, prompt: String?,
                         offset: Double, speaker: Speaker?, shortClip: Bool, checkSilence: Bool, boostQuietAudio: Bool,
                         cancel: RequestCancel) async throws -> ServerTranscription {
        try await loadIfNeeded(model)
        if cancel.isCancelled { throw CancellationError() }
        guard let port, let inferencePath, processIsRunning else {
            throw AppFailure("The speech model is not running.")
        }
        state = .busy
        defer {
            if case .busy = state {
                state = processIsRunning ? .ready : .unloaded
            }
        }
        let duration = Double(samples.count) / Double(whisperSampleRate)
        let context: Int? = shortClip && duration <= 25 ? Self.audioContext(duration: duration) : nil
        speechCheckWarning = nil
        lastAudioGain = 1
        lastPreprocessingSeconds = 0
        lastRepetitionRetry = false
        let originalWAV = WAVEncoder.pcm16(samples)
        var wav = originalWAV
        var speech: [SpeechRange]?
        if boostQuietAudio {
            let begin = Date()
            let prepared = await Task.detached(priority: .userInitiated) { AudioPreprocessor.prepare(samples) }.value
            lastPreprocessingSeconds = Date().timeIntervalSince(begin)
            if prepared.gain > 1 {
                do { speech = try await SpeechActivityDetector.ranges(wav: originalWAV, executable: tool("whisper-vad-speech-segments"), offset: offset) }
                catch is CancellationError { throw CancellationError() }
                catch { speechCheckWarning = "The silence check was unavailable. Short closing phrases may need review." }
                // An empty voice map means room noise. Leave it at its original level.
                if let speech {
                    let focusedStarted = Date()
                    let focused = await Task.detached(priority: .userInitiated) {
                        AudioPreprocessor.restrict(prepared, original: samples, speech: speech, offset: offset)
                    }.value
                    lastPreprocessingSeconds += Date().timeIntervalSince(focusedStarted)
                    wav = WAVEncoder.pcm16(focused.samples)
                    lastAudioGain = focused.gain
                }
            }
        }
        if cancel.isCancelled { throw CancellationError() }
        let data: Data
        do {
            data = try await post(port: port, path: inferencePath, wav: wav, language: language,
                                  prompt: prompt, audioContext: context, cancel: cancel)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            if !processIsRunning {
                throw AppFailure("The speech model stopped. Try again.")
            }
            throw error
        }
        var result: ServerTranscription
        do { result = try TranscriptOutput.parseServer(data, offset: offset, speaker: speaker) }
        catch {
            throw AppFailure("The speech model returned a transcript the app could not read.")
        }
        if !shortClip, RepetitionGuard.score(result.text) > 0 {
            lastRepetitionRetry = true
            do {
                let retry = try await post(port: port, path: inferencePath, wav: originalWAV, language: language,
                                           prompt: nil, audioContext: context, cancel: cancel)
                let candidate = try TranscriptOutput.parseServer(retry, offset: offset, speaker: speaker)
                if RepetitionGuard.prefers(candidate.text, over: result.text) { result = candidate }
            } catch is CancellationError { throw CancellationError() }
            catch { speechCheckWarning = "A repeated passage could not be checked. Review this note's transcript." }
            if RepetitionGuard.score(result.text) > 0 {
                speechCheckWarning = "Some passages contain repeated text and need review."
            }
        }
        if checkSilence, !shortClip, SilenceGuard.needsCheck(result.segments) {
            do {
                let activity: [SpeechRange]
                if let speech { activity = speech }
                else { activity = try await SpeechActivityDetector.ranges(wav: originalWAV, executable: tool("whisper-vad-speech-segments"), offset: offset) }
                if cancel.isCancelled { throw CancellationError() }
                result.segments = SilenceGuard.filter(result.segments, speech: activity)
            } catch is CancellationError { throw CancellationError() }
            catch { speechCheckWarning = "The silence check was unavailable. Short closing phrases may need review." }
        }
        return result
    }

    private func post(port: UInt16, path: String, wav: Data, language: String, prompt: String?,
                      audioContext: Int?, cancel: RequestCancel) async throws -> Data {
        guard let url = Self.endpoint(port: port, path: path) else {
            throw AppFailure("Could not reach the speech model. Try again.")
        }
        let boundary = "WhisperDrop-\(UUID().uuidString)"
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 120
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = Self.multipart(boundary: boundary, wav: wav, language: Self.serverLanguage(language),
                                          prompt: prompt, audioContext: audioContext, preserveWords: preserveWords)
        // The caller's Task is not this chain link, so cancellation is delivered through `cancel`.
        return try await withCheckedThrowingContinuation { continuation in
            let task = session.dataTask(with: request) { data, response, error in
                if let error {
                    let ns = error as NSError
                    if ns.domain == NSURLErrorDomain && ns.code == NSURLErrorCancelled {
                        continuation.resume(throwing: CancellationError())
                    } else {
                        continuation.resume(throwing: AppFailure("Could not reach the speech model. Try again."))
                    }
                    return
                }
                guard let data, let http = response as? HTTPURLResponse else {
                    continuation.resume(throwing: AppFailure("The speech model returned an empty response."))
                    return
                }
                guard http.statusCode == 200 else {
                    let detail = String(decoding: data.prefix(240), as: UTF8.self)
                        .replacingOccurrences(of: "\n", with: " ")
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    let suffix = detail.isEmpty ? "" : " \(detail)"
                    continuation.resume(throwing: AppFailure("Transcription failed (\(http.statusCode)).\(suffix)"))
                    return
                }
                continuation.resume(returning: data)
            }
            cancel.attach(task)
        }
    }

    /// `-l auto` makes omission mean auto-detect. Sending `auto` does the same inside whisper_full,
    /// and a real language code replaces it for this request only. `detect_language` is not sent:
    /// the server would return after detection and skip the transcript.
    private static func serverLanguage(_ language: String) -> String {
        let trimmed = language.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed.caseInsensitiveCompare("auto") == .orderedSame { return "auto" }
        return trimmed
    }

    private static func multipart(boundary: String, wav: Data, language: String, prompt: String?, audioContext: Int?, preserveWords: Bool) -> Data {
        var body = Data()
        func add(_ string: String) { body.append(Data(string.utf8)) }
        add("--\(boundary)\r\n")
        add("Content-Disposition: form-data; name=\"file\"; filename=\"audio.wav\"\r\n")
        add("Content-Type: audio/wav\r\n\r\n")
        body.append(wav)
        add("\r\n")
        var fields = [
            ("response_format", "verbose_json"),
            ("temperature", "0.0"),
            ("no_language_probabilities", "true"),
            ("translate", "false"),
            ("language", language)
        ]
        // Keep word timing for overlap, without the server's 60-character wrapping.
        if preserveWords { fields += [("max_len", "-1"), ("token_timestamps", "true")] }
        if let prompt, !prompt.isEmpty { fields.append(("prompt", prompt)) }
        if let audioContext, audioContext > 0 { fields.append(("audio_ctx", String(audioContext))) }
        for (name, value) in fields {
            add("--\(boundary)\r\n")
            add("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n")
            add(value)
            add("\r\n")
        }
        add("--\(boundary)--\r\n")
        return body
    }

    // MARK: - Idle

    private func armIdleTimer() {
        reevaluateIdle(resetClock: true)
    }

    private func reevaluateIdle(resetClock: Bool) {
        idleGeneration &+= 1
        idleTask?.cancel()
        idleTask = nil
        let seconds = residency.idleSeconds
        let eligible = !isShutDown && !keepReady && seconds != nil && leases.isEmpty && pending == 0
            && state == .ready && processIsRunning
        guard eligible, let seconds else {
            if !eligible { becameIdleAt = nil }
            return
        }
        if resetClock || becameIdleAt == nil { becameIdleAt = Date() }
        let start = becameIdleAt ?? Date()
        let remaining = seconds - Date().timeIntervalSince(start)
        if remaining <= 0 {
            becameIdleAt = nil
            unload()
            return
        }
        let generation = idleGeneration
        idleTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000_000))
            guard let self, !Task.isCancelled, generation == self.idleGeneration else { return }
            self.reevaluateIdle(resetClock: false)
        }
    }

    // MARK: - Process

    private var processIsRunning: Bool { process?.isRunning == true }

    private func stopServer(intentional: Bool) {
        intentionalStop = true
        lifetime += 1
        let pid = process?.processIdentifier ?? 0
        if let process, process.isRunning {
            process.terminate()
            if pid > 0 && !Self.waitUntilGone(pid, timeout: 1) {
                kill(pid, SIGKILL)
                _ = Self.waitUntilGone(pid, timeout: 0.5)
            }
        }
        detachProcess()
        _ = intentional
    }

    private func handleExit(pid: pid_t) {
        guard process?.processIdentifier == pid else { return }
        let failedDuringLoad = state == .loading && !intentionalStop
        let alreadyFailed: Bool
        if case .failed = state { alreadyFailed = true } else { alreadyFailed = false }
        let message = loadFailureMessage()
        detachProcess()
        guard !intentionalStop, !alreadyFailed else { return }
        state = failedDuringLoad ? .failed(message) : .unloaded
    }

    private func detachProcess() {
        errorPipe?.fileHandleForReading.readabilityHandler = nil
        errorPipe = nil
        process = nil
        port = nil
        inferencePath = nil
        loadedModel = nil
        removePIDFile()
    }

    private func capture(_ pipe: Pipe) {
        let tail = stderrTail
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                return
            }
            tail.append(data)
        }
    }

    private func loadFailureMessage() -> String {
        let lines = stderrTail.text()
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard let last = lines.last else { return "The speech model stopped while loading." }
        let detail = last.count > 240 ? String(last.suffix(240)) : String(last)
        return "The speech model stopped while loading. \(detail)"
    }

    private static func arguments(modelPath: String, port: UInt16, inferencePath: String) -> [String] {
        let cores = ProcessInfo.processInfo.activeProcessorCount
        let threads = min(6, max(2, cores - 2))
        return ["--host", "127.0.0.1", "--port", String(port), "-m", modelPath,
                "-t", String(threads), "-l", "auto", "--inference-path", inferencePath]
    }

    private static func launchEnvironment(executable: URL) -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = executable.deletingLastPathComponent().path + ":/usr/bin:/bin:/usr/sbin:/sbin"
        environment["LC_ALL"] = "en_US.UTF-8"
        return environment
    }

    private static func endpoint(port: UInt16, path: String) -> URL? {
        var components = URLComponents()
        components.scheme = "http"
        components.host = "127.0.0.1"
        components.port = Int(port)
        components.path = path
        return components.url
    }

    private static func makeSession(requestTimeout: TimeInterval, resourceTimeout: TimeInterval) -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = requestTimeout
        configuration.timeoutIntervalForResource = resourceTimeout
        configuration.waitsForConnectivity = false
        return URLSession(configuration: configuration)
    }

    private static func userFacing(_ error: Error) -> String {
        if let localized = error as? LocalizedError, let text = localized.errorDescription, !text.isEmpty {
            return text
        }
        let text = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? "The speech model could not be loaded." : text
    }

    /// Bind a loopback socket to port 0, read the kernel-assigned port, and close it.
    private static func reserveLoopbackPort() throws -> UInt16 {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw AppFailure("Could not open a local socket for the speech model.") }
        defer { close(descriptor) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.stride)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(0)
        let parsed = withUnsafeMutablePointer(to: &address.sin_addr) { pointer in
            inet_pton(AF_INET, "127.0.0.1", pointer)
        }
        guard parsed == 1 else { throw AppFailure("Could not prepare a local address for the speech model.") }
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { raw in
                Darwin.bind(descriptor, raw, socklen_t(MemoryLayout<sockaddr_in>.stride))
            }
        }
        guard bound == 0 else { throw AppFailure("Could not reserve a local port for the speech model.") }
        var length = socklen_t(MemoryLayout<sockaddr_in>.stride)
        let named = withUnsafeMutablePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { raw in
                getsockname(descriptor, raw, &length)
            }
        }
        guard named == 0 else { throw AppFailure("Could not read the reserved local port.") }
        let port = UInt16(bigEndian: address.sin_port)
        guard port != 0 else { throw AppFailure("The reserved local port was empty.") }
        return port
    }

    // MARK: - Stale process

    private func reapStaleServer() {
        let url = processFile
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return }
        let parts = text.split(whereSeparator: \.isWhitespace).map(String.init)
        defer { try? FileManager.default.removeItem(at: url) }
        guard parts.count >= 2, parts[1] == Self.pidMarker, let pid = pid_t(parts[0]), pid > 0 else { return }
        guard Self.commandName(pid) == "whisper-server" else { return }
        Self.terminate(pid)
    }

    private func writePIDFile(_ pid: pid_t) {
        livePID = pid
        let url = processFile
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try "\(pid) \(Self.pidMarker)\n".write(to: url, atomically: true, encoding: .utf8)
        } catch {
            // The child is still tracked in memory. A crash of this app may leave it behind.
        }
    }

    private func removePIDFile() {
        livePID = 0
        try? FileManager.default.removeItem(at: processFile)
    }

    nonisolated private static func terminate(_ pid: pid_t) {
        guard pid > 0, kill(pid, 0) == 0 else { return }
        kill(pid, SIGTERM)
        if waitUntilGone(pid, timeout: 1) { return }
        kill(pid, SIGKILL)
        _ = waitUntilGone(pid, timeout: 0.5)
    }

    nonisolated private static func waitUntilGone(_ pid: pid_t, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if !stillExists(pid) { return true }
            Thread.sleep(forTimeInterval: 0.02)
        }
        return !stillExists(pid)
    }

    /// `kill(pid, 0)` stays true for a zombie. Reap our own child so the pid is actually gone.
    nonisolated private static func stillExists(_ pid: pid_t) -> Bool {
        var status: Int32 = 0
        let reaped = waitpid(pid, &status, WNOHANG)
        if reaped == pid { return false }
        if reaped == 0 { return true }
        return kill(pid, 0) == 0
    }

    nonisolated private static func commandName(_ pid: pid_t) -> String? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, u_int(mib.count), &info, &size, nil, 0) == 0, size > 0 else { return nil }
        return withUnsafeBytes(of: info.kp_proc.p_comm) { bytes in
            guard let base = bytes.bindMemory(to: CChar.self).baseAddress else { return nil }
            return String(cString: base)
        }
    }
}

private final class StderrTail: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = Data()
    private let limit = 32 * 1024

    func append(_ data: Data) {
        guard !data.isEmpty else { return }
        lock.lock()
        storage.append(data)
        if storage.count > limit { storage.removeFirst(storage.count - limit) }
        lock.unlock()
    }

    func text() -> String {
        lock.lock()
        let storage = storage
        lock.unlock()
        return String(decoding: storage, as: UTF8.self)
    }

    func reset() {
        lock.lock()
        storage.removeAll(keepingCapacity: true)
        lock.unlock()
    }
}

/// Cancels the in-flight inference task when the caller's Task is cancelled.
private final class RequestCancel: @unchecked Sendable {
    private let lock = NSLock()
    private var task: URLSessionTask?
    private var cancelled = false

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    func attach(_ task: URLSessionTask) {
        lock.lock()
        self.task = task
        let cancelled = cancelled
        lock.unlock()
        task.resume()
        if cancelled { task.cancel() }
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let task = task
        lock.unlock()
        task?.cancel()
    }
}
