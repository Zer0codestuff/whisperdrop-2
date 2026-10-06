import Foundation
import Darwin
import WhisperDropCore

struct TextGenerationMetrics: Codable, Sendable {
    var contextTokens = 0
    var inputTokens = 0
    var inputChunks = 0
    var completionRequests = 0
    var generatedTokens = 0
    var elapsedSeconds = 0.0
    var peakResidentMB = 0
    var usedSmallContextFallback = false
}

/// One on-demand, loopback-only llama.cpp process shared by writing actions and note summaries.
@MainActor
final class TextGenerationEngine: ObservableObject {
    enum State: String { case off = "Off", loading = "Loading", ready = "Ready" }
    @Published private(set) var state: State = .off
    @Published private(set) var loadedModelID: String?
    @Published private(set) var loadedContextTokens: Int?
    @Published private(set) var lastRun: TextGenerationMetrics?
    @Published private(set) var isGenerating = false
    @Published private(set) var processingDetail: String?
    @Published private(set) var memoryMB = 0
    @Published var error: String?
    private let runtime: () throws -> URL
    private let processFile: URL
    private let physicalMemoryBytes: UInt64
    private let completionTimeout: TimeInterval
    private var process: Process?
    private var closingProcesses: [Process] = []
    private var baseURL: URL?
    private var session: URLSession?
    private var token = ""
    private var loadedFile: URL?
    private var generationID = UUID()
    private var activeRequestID: UUID?
    private var bannedTokens: [Int] = []
    private var monitor: Task<Void, Never>?
    private var lastUse = Date()
    private let stderr = TextEngineStderr()
    private var measuringRequestID: UUID?
    private var runMetrics: TextGenerationMetrics?
    var processID: Int32? { process?.processIdentifier }
    private static let pidMarker = "WhisperDropTextServer1"

    init(runtime: @escaping () throws -> URL, processFile: URL,
         physicalMemoryBytes: UInt64 = ProcessInfo.processInfo.physicalMemory, completionTimeout: TimeInterval = 600) {
        self.runtime = runtime; self.processFile = processFile
        self.physicalMemoryBytes = physicalMemoryBytes
        self.completionTimeout = completionTimeout
        reapStaleProcess()
    }

    func unload() { stopProcess(clearRequest: true) }

    func generate(text: String, action: TextAction, instruction: String = "", style: String = "",
                  model: TextModel, file: URL, context: TextContextMode = .automatic) async throws -> String {
        guard activeRequestID == nil else { throw TextToolError.busy }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw TextToolError.message("Select or enter some text first.") }
        let requestID = UUID(); activeRequestID = requestID; isGenerating = true; error = nil
        let started = Date()
        measuringRequestID = requestID; runMetrics = TextGenerationMetrics(); lastRun = nil
        processingDetail = "Loading \(model.name)…"
        defer {
            if measuringRequestID == requestID {
                runMetrics?.elapsedSeconds = Date().timeIntervalSince(started)
                lastRun = runMetrics; runMetrics = nil; measuringRequestID = nil
            }
            // An unload followed by another action must not let the old request change the new one's state.
            if activeRequestID == requestID {
                activeRequestID = nil; isGenerating = false; processingDetail = nil; lastUse = Date()
            }
        }
        do {
            // This estimate only chooses the first allocation. The loaded tokenizer controls all
            // subsequent context decisions and chunk boundaries.
            let estimated = TextContextPolicy.context(mode: context, inputTokens: text.utf8.count / 4,
                promptOverhead: (instruction.utf8.count + style.utf8.count) / 4 + 256,
                action: action, modelMaximum: model.maximumContextTokens, physicalMemoryBytes: physicalMemoryBytes)
            let automaticMaximum = min(model.maximumContextTokens, TextContextPolicy.automaticMaximum(physicalMemoryBytes: physicalMemoryBytes))
            let initial = context == .automatic && loadedModelID == model.id && loadedFile == file
                ? min(loadedContextTokens ?? estimated, automaticMaximum) : estimated
            try await loadWithFallback(model: model, file: file, contextTokens: initial, allowFallback: context == .automatic)
            try check(requestID: requestID)
            let inputTokens = try await tokenCount(text)
            let fullRequest = TextToolRequest(text: text, action: action, instruction: instruction, style: style)
            let promptTokens = try await tokenCount(fullRequest.systemPrompt + "\n" + fullRequest.userPrompt)
            var overhead = max(0, promptTokens - inputTokens) + 128
            if action.isSummary {
                // Section and combination instructions also consume context. Measure them before
                // splitting, including a conservative section index, rather than borrowing output space.
                for detail in [summarySectionInstruction(instruction, index: Int.max, count: Int.max), summaryReductionInstruction(instruction)] {
                    let staged = TextToolRequest(text: text, action: action, instruction: detail, style: style)
                    let stagedTokens = try await tokenCount(staged.systemPrompt + "\n" + staged.userPrompt)
                    overhead = max(overhead, max(0, stagedTokens - inputTokens) + 128)
                }
            }
            runMetrics?.inputTokens = inputTokens
            let recommended = TextContextPolicy.context(mode: context, inputTokens: inputTokens, promptOverhead: overhead,
                action: action, modelMaximum: model.maximumContextTokens, physicalMemoryBytes: physicalMemoryBytes)
            let keepLoaded = context == .automatic && (loadedContextTokens ?? 0) >= recommended && (loadedContextTokens ?? 0) <= automaticMaximum
            if !keepLoaded && runMetrics?.usedSmallContextFallback != true {
                try await loadWithFallback(model: model, file: file, contextTokens: recommended, allowFallback: context == .automatic)
            }
            try check(requestID: requestID)
            let epoch = generationID
            guard let contextTokens = loadedContextTokens else { throw CancellationError() }
            runMetrics?.contextTokens = contextTokens
            startMonitoring()
            let budget = TextContextPolicy.inputBudget(contextTokens: contextTokens, promptOverhead: overhead, action: action)
            guard budget >= 256 else { throw TextToolError.message("The action instruction or writing style is too long. Shorten it in Settings.") }
            processingDetail = "Reading text…"
            let pieces = try await TextToolChunks.split(text, maximumTokens: budget) { [weak self] value in
                guard let self else { throw CancellationError() }
                try self.check(requestID: requestID, epoch: epoch)
                return try await self.tokenCount(value)
            }
            runMetrics?.inputChunks = pieces.count
            var results: [String] = []
            let separateParagraphs = action.isSummary || action.id == "organize"
            for (index, piece) in pieces.enumerated() {
                try check(requestID: requestID, epoch: epoch)
                processingDetail = pieces.count == 1 ? action.title + "…" : "\(action.title): part \(index + 1) of \(pieces.count)"
                let detail = action.isSummary && pieces.count > 1
                    ? summarySectionInstruction(instruction, index: index + 1, count: pieces.count) : instruction
                let request = TextToolRequest(text: piece, action: action, instruction: detail, style: style)
                let pieceTokens = try await tokenCount(piece)
                let outputLimit = TextContextPolicy.outputTokens(inputTokens: pieceTokens, action: action)
                let cleaned = try await revisedText(request, limit: action.isSummary && pieces.count > 1 ? 700 : outputLimit, model: model)
                try check(requestID: requestID, epoch: epoch)
                results.append(separateParagraphs ? cleaned : TextToolRequest.preservingEdgeWhitespace(cleaned, of: piece))
            }
            var result = results.joined(separator: separateParagraphs ? "\n\n" : "")
            if action.isSummary, pieces.count > 1 {
                // Map/reduce includes every source part. It does not crop the end of a long note to fit context.
                var round = 0
                while true {
                    try check(requestID: requestID, epoch: epoch)
                    round += 1
                    guard round <= 8 else { throw TextToolError.message("This note is too long to combine into one reliable summary. Summarize smaller sections. Your original note is unchanged.") }
                    let groups = try await TextToolChunks.split(result, maximumTokens: budget) { [weak self] value in
                        guard let self else { throw CancellationError() }
                        try self.check(requestID: requestID, epoch: epoch)
                        return try await self.tokenCount(value)
                    }
                    var reduced: [String] = []
                    for (index, group) in groups.enumerated() {
                        processingDetail = groups.count == 1 ? "Combining the summary…" : "Combining summaries: part \(index + 1) of \(groups.count)"
                        let detail = summaryReductionInstruction(instruction)
                        let request = TextToolRequest(text: group, action: action, instruction: detail, style: style)
                        // The extra reduction instruction also consumes context; check the full prompt.
                        try await validateContext(request, outputLimit: groups.count == 1 ? 1200 : 700, model: model)
                        let cleaned = try await revisedText(request, limit: groups.count == 1 ? 1200 : 700, model: model)
                        try check(requestID: requestID, epoch: epoch)
                        reduced.append(cleaned)
                    }
                    let previousTokens = try await tokenCount(result)
                    result = reduced.joined(separator: "\n\n")
                    if groups.count == 1 { break }
                    guard try await tokenCount(result) < previousTokens else {
                        throw TextToolError.message("The model did not shorten the partial summaries enough to combine them. Try again. Your original note is unchanged.")
                    }
                }
            }
            try check(requestID: requestID, epoch: epoch)
            return TextToolRequest.preservingEdgeWhitespace(result, of: text)
        } catch {
            // URLSession reports cancelled requests as URLError.cancelled. Normalize explicit cancellation
            // so automatic note summaries can be requeued when capture interrupts text generation.
            if Task.isCancelled || activeRequestID != requestID { throw CancellationError() }
            if (error as NSError).code == NSURLErrorTimedOut {
                // A non-streaming server can still be decoding after the client disconnects.
                // Release it so a subsequent action never queues behind an abandoned request.
                stopProcess(clearRequest: false)
                let message = "The text action took too long. Try a smaller working context or another model in Settings, Models. Your original text is unchanged."
                self.error = message
                throw TextToolError.message(message)
            }
            if let stopped = self.error { throw TextToolError.message(stopped) }
            if error is CancellationError || (error as NSError).code == NSURLErrorCancelled { throw CancellationError() }
            self.error = error.localizedDescription
            throw error
        }
    }

    private func check(requestID: UUID, epoch: UUID? = nil) throws {
        try Task.checkCancellation()
        guard activeRequestID == requestID, epoch == nil || generationID == epoch else { throw CancellationError() }
    }

    private func summarySectionInstruction(_ instruction: String, index: Int, count: Int) -> String {
        instruction + "\nThis is source section \(index) of \(count). Retain explicit names and their roles or commitments needed for the final summary. Make this partial summary self-contained. Label provisional decisions as provisional; later sections may update them. Do not replace named assignments with vague references to earlier responsibilities."
    }

    private func summaryReductionInstruction(_ instruction: String) -> String {
        instruction + "\nThese are summaries of consecutive source sections. Combine them, remove duplicated points and retain the important facts in their original language. Resolve later explicitly confirmed decisions over earlier provisional ones. Keep names with their roles or commitments. Expand references to earlier assignments only using names and roles present in these summaries."
    }

    private func loadWithFallback(model: TextModel, file: URL, contextTokens: Int, allowFallback: Bool) async throws {
        do { try await load(model: model, file: file, contextTokens: contextTokens) }
        catch {
            guard allowFallback, contextTokens > 8192, !Task.isCancelled, !(error is CancellationError) else { throw error }
            runMetrics?.usedSmallContextFallback = true
            self.error = nil
            try await load(model: model, file: file, contextTokens: 8192)
        }
    }

    private func load(model: TextModel, file: URL, contextTokens: Int) async throws {
        if state == .ready, loadedModelID == model.id, loadedFile == file, loadedContextTokens == contextTokens, process?.isRunning == true { return }
        stopProcess(clearRequest: false)
        // Release the old allocation before resizing on Macs with little shared memory.
        // An earlier explicit unload may already have detached a server that is still exiting.
        for _ in 0..<40 where closingProcesses.contains(where: { $0.isRunning }) {
            try Task.checkCancellation()
            try await Task.sleep(for: .milliseconds(50))
        }
        guard !closingProcesses.contains(where: { $0.isRunning }) else { throw TextToolError.message("The previous text model is still closing. Try the action again.") }
        closingProcesses.removeAll()
        let id = generationID
        guard FileManager.default.isReadableFile(atPath: file.path) else {
            throw TextToolError.message("Download or choose \(model.name) in Settings, Models before using text actions.")
        }
        let executable = try runtime()
        let port = try Self.loopbackPort()
        let url = URL(string: "http://127.0.0.1:\(port)")!
        let p = Process()
        let pipe = Pipe()
        stderr.reset()
        pipe.fileHandleForReading.readabilityHandler = { [stderr] handle in stderr.append(handle.availableData) }
        token = UUID().uuidString
        p.executableURL = executable
        p.arguments = ["--model", file.path, "--host", "127.0.0.1", "--port", String(port), "--api-key", token,
                       "--ctx-size", String(contextTokens), "--parallel", "1", "--n-gpu-layers", "99", "--threads", "4",
                       "--no-webui", "--jinja", "--reasoning-budget", "0", "--cache-ram", "0"]
        p.standardOutput = FileHandle.nullDevice; p.standardError = pipe; p.standardInput = FileHandle.nullDevice
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 180; config.timeoutIntervalForResource = 900
        session = URLSession(configuration: config)
        p.terminationHandler = { [weak self] ended in
            pipe.fileHandleForReading.readabilityHandler = nil
            Task { @MainActor [weak self] in
                guard let self, self.process === ended else { return }
                let message = "The local text model stopped. Try the action again or choose another model in Settings, Models."
                self.stopProcess(clearRequest: false); self.error = message
            }
        }
        state = .loading; process = p; baseURL = url
        do {
            try p.run()
            writePID(p.processIdentifier, executable: executable)
            for _ in 0..<180 {
                try Task.checkCancellation()
                guard generationID == id else { throw CancellationError() }
                guard p.isRunning else {
                    throw TextToolError.message("The local text model could not load. Download the model again or choose another one in Settings, Models.")
                }
                var request = try authorizedRequest("health"); request.timeoutInterval = 1
                if let session, let (_, response) = try? await session.data(for: request), (response as? HTTPURLResponse)?.statusCode == 200 {
                    bannedTokens = await specialTokenIDs(["<|tool_call_start|>", "<think>", "<|tool_call|>"])
                    try Task.checkCancellation()
                    guard generationID == id else { throw CancellationError() }
                    loadedModelID = model.id; loadedFile = file; loadedContextTokens = contextTokens
                    state = .ready; lastUse = Date(); startMonitoring(); return
                }
                try await Task.sleep(for: .milliseconds(500))
            }
            throw TextToolError.message("The local text model did not load within 90 seconds. Try again or choose the smaller model.")
        } catch {
            if generationID == id { stopProcess(clearRequest: false) }
            throw error
        }
    }

    private func authorizedRequest(_ path: String) throws -> URLRequest {
        guard let baseURL else { throw CancellationError() }
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        return request
    }

    private func tokenCount(_ text: String) async throws -> Int {
        guard let session, baseURL != nil else { throw CancellationError() }
        let epoch = generationID
        var request = try authorizedRequest("tokenize")
        request.httpMethod = "POST"; request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["content": text, "parse_special": false])
        let (data, response) = try await session.data(for: request)
        try Task.checkCancellation()
        guard generationID == epoch else { throw CancellationError() }
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tokens = object["tokens"] as? [Int] else {
            throw TextToolError.message("The text model could not measure this request. Try loading it again.")
        }
        return tokens.count
    }

    private func validateContext(_ request: TextToolRequest, outputLimit: Int, model: TextModel) async throws {
        let count = try await tokenCount(request.systemPrompt + "\n" + request.userPrompt)
        guard let contextTokens = loadedContextTokens else { throw CancellationError() }
        guard count + outputLimit + TextContextPolicy.safetyTokens <= contextTokens else {
            throw TextToolError.message("The text action does not fit the model context. Shorten the extra instruction or writing style. Your original text is unchanged.")
        }
    }

    private func revisedText(_ request: TextToolRequest, limit: Int, model: TextModel) async throws -> String {
        let epoch = generationID
        var cleaned: String?
        do {
            let raw = try await completion(request, limit: limit, model: model)
            cleaned = try TextToolRequest.cleanOutput(raw, original: request.text, action: request.action)
        } catch TextToolError.invalidResponse where request.action.isSummary {
            // A length-stopped summary is not publishable. Give the original facts one concise
            // attempt instead of accepting or truncating a partial response.
        }
        if let cleaned, !request.action.isSummary || !TextToolRequest.summaryIsTooLong(cleaned, original: request.text) { return cleaned }
        try Task.checkCancellation()
        guard generationID == epoch else { throw CancellationError() }
        processingDetail = "Shortening the summary…"
        let wordLimit = TextToolRequest.summaryWordLimit(for: request.text) ?? 20
        let detail = request.instruction + "\nCreate at most three short bullets with a total of at most \(wordLimit) words. Keep only the main points. Do not rewrite sentence by sentence. Preserve important facts accurately."
        // Retry once against the original facts, never against the first model's possibly mistaken rewrite.
        let retry = TextToolRequest(text: request.text, action: request.action, instruction: detail)
        let retryRaw = try await completion(retry, limit: min(limit, max(200, wordLimit * 4)), model: model)
        let shortened = try TextToolRequest.cleanOutput(retryRaw, original: request.text, action: request.action)
        guard !TextToolRequest.summaryIsTooLong(shortened, original: request.text) else {
            throw TextToolError.message("The model rewrote too much of the transcript instead of producing a concise summary. Your original text is unchanged. Try again or choose another text model.")
        }
        return shortened
    }

    private func completion(_ value: TextToolRequest, limit: Int, model: TextModel) async throws -> String {
        guard let session, baseURL != nil else { throw CancellationError() }
        let epoch = generationID
        try await validateContext(value, outputLimit: limit, model: model)
        try Task.checkCancellation()
        guard generationID == epoch else { throw CancellationError() }
        var request = try authorizedRequest("v1/chat/completions")
        request.httpMethod = "POST"
        // Prompt evaluation dominates long-note summaries even with a short output reserve.
        request.timeoutInterval = completionTimeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        var messages = [["role": "user", "content": value.userPrompt]]
        if !value.systemPrompt.isEmpty { messages.insert(["role": "system", "content": value.systemPrompt], at: 0) }
        var body: [String: Any] = ["messages": messages, "temperature": model.id == "minicpm5-1b" ? 0.7 : 0.1,
                                   "max_tokens": limit, "stream": false, "cache_prompt": false,
                                   "chat_template_kwargs": ["enable_thinking": false]]
        if model.id == "minicpm5-1b" { body["top_p"] = 0.95; body["min_p"] = 0.0 }
        if !bannedTokens.isEmpty { body["logit_bias"] = Dictionary(uniqueKeysWithValues: bannedTokens.map { (String($0), -100) }) }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        runMetrics?.completionRequests += 1
        let (data, response) = try await session.data(for: request)
        try Task.checkCancellation()
        guard generationID == epoch else { throw CancellationError() }
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw TextToolError.message("The local text model could not complete this action. Try again. Your original text is unchanged.")
        }
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw TextToolError.invalidResponse }
        if let usage = object["usage"] as? [String: Any], let generated = usage["completion_tokens"] as? Int {
            runMetrics?.generatedTokens += generated
        }
        sampleMemory()
        guard let choices = object["choices"] as? [[String: Any]], let first = choices.first,
              first["finish_reason"] as? String == "stop",
              let message = first["message"] as? [String: Any], let text = message["content"] as? String else { throw TextToolError.invalidResponse }
        return text
    }

    private func specialTokenIDs(_ pieces: [String]) async -> [Int] {
        guard let session else { return [] }
        let epoch = generationID
        var ids = Set<Int>()
        for piece in pieces {
            guard !Task.isCancelled, generationID == epoch, var request = try? authorizedRequest("tokenize") else { return [] }
            request.httpMethod = "POST"; request.timeoutInterval = 2
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try? JSONSerialization.data(withJSONObject: ["content": piece, "parse_special": true, "with_pieces": true])
            guard let (data, response) = try? await session.data(for: request), (response as? HTTPURLResponse)?.statusCode == 200,
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let tokens = object["tokens"] as? [[String: Any]], tokens.count == 1,
                  tokens[0]["piece"] as? String == piece, let id = tokens[0]["id"] as? Int else { continue }
            guard generationID == epoch else { return [] }
            ids.insert(id)
        }
        return Array(ids)
    }

    private func stopProcess(clearRequest: Bool) {
        generationID = UUID(); monitor?.cancel(); monitor = nil
        session?.invalidateAndCancel(); session = nil
        let p = process; process = nil
        closingProcesses.removeAll { !$0.isRunning }
        if p != nil { try? FileManager.default.removeItem(at: processFile) }
        if let p, p.isRunning {
            closingProcesses.append(p)
            p.terminate()
            Task {
                try? await Task.sleep(for: .seconds(1))
                if p.isRunning { kill(p.processIdentifier, SIGKILL) }
            }
        }
        state = .off; loadedModelID = nil; loadedFile = nil; loadedContextTokens = nil; memoryMB = 0; baseURL = nil; token = ""; bannedTokens = []
        if clearRequest { activeRequestID = nil; isGenerating = false; processingDetail = nil }
    }

    private func startMonitoring() {
        monitor?.cancel()
        sampleMemory()
        monitor = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, let p = self.process, p.isRunning else { return }
                self.sampleMemory()
                if self.activeRequestID == nil, Date().timeIntervalSince(self.lastUse) >= 300 { self.unload(); return }
                try? await Task.sleep(for: self.isGenerating ? .milliseconds(250) : .seconds(3))
            }
        }
    }

    private func sampleMemory() {
        guard let p = process, p.isRunning else { return }
        var info = proc_taskinfo()
        if proc_pidinfo(p.processIdentifier, PROC_PIDTASKINFO, 0, &info, Int32(MemoryLayout<proc_taskinfo>.size)) > 0 {
            memoryMB = Int(info.pti_resident_size / 1_048_576)
            let peak = max(runMetrics?.peakResidentMB ?? 0, memoryMB)
            runMetrics?.peakResidentMB = peak
        }
    }

    private func writePID(_ pid: pid_t, executable: URL) {
        try? FileManager.default.createDirectory(at: processFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? "\(pid)\n\(Self.pidMarker)\n\(executable.standardizedFileURL.path)\n".write(to: processFile, atomically: true, encoding: .utf8)
    }
    private func reapStaleProcess() {
        guard let text = try? String(contentsOf: processFile, encoding: .utf8) else { return }
        defer { try? FileManager.default.removeItem(at: processFile) }
        let lines = text.components(separatedBy: "\n")
        guard lines.count >= 3, lines[1] == Self.pidMarker, let pid = Int32(lines[0]), pid > 0 else { return }
        var buffer = [CChar](repeating: 0, count: 4096)
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return }
        let path = String(cString: buffer)
        guard path == lines[2], URL(fileURLWithPath: path).lastPathComponent == "llama-server" else { return }
        kill(pid, SIGTERM)
    }

    private static func loopbackPort() throws -> UInt16 {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw TextToolError.message("Could not open a local socket for the text model.") }
        defer { close(fd) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.stride); address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0; address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.stride)) }
        }
        guard result == 0 else { throw TextToolError.message("Could not reserve a local port for the text model.") }
        var length = socklen_t(MemoryLayout<sockaddr_in>.stride)
        let named = withUnsafeMutablePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
        }
        guard named == 0 else { throw TextToolError.message("Could not read the text model's local port.") }
        return UInt16(bigEndian: address.sin_port)
    }
}

private final class TextEngineStderr: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = Data()
    func append(_ data: Data) {
        lock.lock(); defer { lock.unlock() }
        storage.append(data)
        if storage.count > 16_384 { storage.removeFirst(storage.count - 16_384) }
    }
    func reset() { lock.lock(); storage.removeAll(); lock.unlock() }
}
