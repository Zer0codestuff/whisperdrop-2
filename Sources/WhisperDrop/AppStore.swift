import AppKit
import SwiftUI
import UniformTypeIdentifiers
import WhisperDropCore

@MainActor
final class AppStore: ObservableObject {
    @Published var jobs: [TranscriptionJob] = []
    @Published var selection: UUID?
    @Published var selectedModel = "turbo" {
        didSet { preferences.set(selectedModel, forKey: "model") }
    }
    @Published var language = "auto" {
        didSet { preferences.set(language, forKey: "language") }
    }
    @Published var busy = false
    @Published var importing = false
    @Published var status = "Ready"
    @Published var progress: Double = 0
    @Published var error: String?
    @Published var downloaded: Set<String> = []
    @Published var downloadingModel: String?
    @Published var modelProgress = 0.0
    @Published var diagnostics = ""
    @Published var showModels = false
    @Published var showLink = false
    @Published var showDiagnostics = false
    @Published private(set) var savedFolder: URL
    @Published private(set) var movingSavedFiles = false
    private var work: Task<Void, Never>?
    private var importWork: Task<Void, Never>?
    private var modelWork: Task<Void, Never>?
    private let runner = CommandRunner()
    private let preferences: UserDefaults
    let root: URL
    var canMoveSavedFiles: () -> Bool = { true }
    var audioBoostEnabled: () -> Bool = { true }
    let modelsFolder: URL
    var outputFolder: URL { savedFolder.appendingPathComponent("Transcripts", isDirectory: true) }
    var audioFolder: URL { savedFolder.appendingPathComponent("Audio", isDirectory: true) }
    var canRecordNotes: Bool { libraryReadable && !movingSavedFiles }
    private let historyURL: URL
    private var libraryReadable = true
    private var pendingPreviousFolder: URL?
    var current: TranscriptionJob? { jobs.first { $0.id == selection } }
    var model: TranscriptionModel { TranscriptionModel.catalog.first { $0.id == selectedModel } ?? TranscriptionModel.catalog[4] }
    var queuedCount: Int { jobs.filter { $0.status == .queued }.count }
    static let languages: [(String, String)] = [("auto", "Detect language"), ("it", "Italian"), ("en", "English"), ("es", "Spanish"), ("fr", "French"), ("de", "German"), ("pt", "Portuguese"), ("ja", "Japanese"), ("zh", "Chinese"), ("ko", "Korean"), ("ru", "Russian"), ("ar", "Arabic"), ("nl", "Dutch"), ("pl", "Polish"), ("uk", "Ukrainian"), ("tr", "Turkish")]

    init(root: URL? = nil) {
        preferences = root == nil ? .standard : UserDefaults(suiteName: "io.github.zer0codestuff.whisperdrop2.verification")!
        self.root = root ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("WhisperDrop 2")
        modelsFolder = self.root.appendingPathComponent("Models")
        savedFolder = root.map { $0.appendingPathComponent("Saved", isDirectory: true) }
            ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("WhisperDrop", isDirectory: true)
        historyURL = self.root.appendingPathComponent("history.json")
        do {
            try FileManager.default.createDirectory(at: modelsFolder, withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: historyURL.path) {
                libraryReadable = false
                let data = try Data(contentsOf: historyURL)
                if let snapshot = try? JSONDecoder().decode(LibrarySnapshot.self, from: data) {
                    savedFolder = snapshot.savedFolder
                    jobs = snapshot.jobs
                    pendingPreviousFolder = snapshot.pendingPreviousFolder
                } else { jobs = try JSONDecoder().decode([TranscriptionJob].self, from: data) }
                libraryReadable = true
                for i in jobs.indices where jobs[i].status.isActive { jobs[i].status = .queued }
            }
            let migration = try SavedLibrary.migrate(jobs: jobs, from: pendingPreviousFolder, legacyRoot: self.root, to: savedFolder)
            jobs = migration.jobs
            try JSONEncoder().encode(LibrarySnapshot(savedFolder: savedFolder, jobs: jobs, pendingPreviousFolder: pendingPreviousFolder)).write(to: historyURL, options: .atomic)
            try migration.finish()
            try JSONEncoder().encode(LibrarySnapshot(savedFolder: savedFolder, jobs: jobs)).write(to: historyURL, options: .atomic)
            pendingPreviousFolder = nil
            for job in jobs where job.status == .completed && job.resolvedKind == .note {
                if !FileManager.default.fileExists(atPath: job.source.appendingPathComponent("transcript.txt").path) {
                    try SavedLibrary.archive(job, in: job.source, preserveExistingRecovery: true)
                }
            }
        } catch { self.error = "Could not load the library: \(error.localizedDescription)" }
        selectedModel = preferences.string(forKey: "model") ?? "turbo"
        language = preferences.string(forKey: "language") ?? "auto"
        selection = jobs.first?.id
        refreshModels()
    }

    func tool(_ name: String) throws -> URL {
        let paths = [Bundle.main.resourceURL?.appendingPathComponent("Runtime/bin/\(name)"),
                     URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".runtime/bin/\(name)")]
        guard let path = paths.compactMap({ $0 }).first(where: { FileManager.default.isExecutableFile(atPath: $0.path) }) else {
            throw AppFailure("\(name) is missing from this app. Rebuild with scripts/build-app.sh or install a complete WhisperDrop 2 build.")
        }
        return path
    }
    func save() {
        guard libraryReadable else { return }
        do { try JSONEncoder().encode(LibrarySnapshot(savedFolder: savedFolder, jobs: jobs, pendingPreviousFolder: pendingPreviousFolder)).write(to: historyURL, options: .atomic) }
        catch { self.error = "Could not save the library: \(error.localizedDescription)" }
    }
    func chooseSavedFolder() {
        guard libraryReadable, pendingPreviousFolder == nil, !busy, !importing, !movingSavedFiles, canMoveSavedFiles() else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = savedFolder
        panel.prompt = "Choose folder"
        panel.message = "Audio and Transcripts will be saved here. Existing saved files will move with your library."
        panel.begin { [weak self] response in
            guard response == .OK, let folder = panel.url else { return }
            Task { @MainActor in await self?.changeSavedFolder(to: folder) }
        }
    }
    func changeSavedFolder(to folder: URL) async {
        guard libraryReadable, pendingPreviousFolder == nil, !busy, !importing, !movingSavedFiles, canMoveSavedFiles() else { return }
        movingSavedFiles = true
        defer { movingSavedFiles = false }
        let old = savedFolder, currentJobs = jobs, legacy = root
        do {
            let migration = try await Task.detached(priority: .userInitiated) {
                try SavedLibrary.migrate(jobs: currentJobs, from: old, legacyRoot: legacy, to: folder)
            }.value
            let target = folder.standardizedFileURL.resolvingSymlinksInPath()
            try JSONEncoder().encode(LibrarySnapshot(savedFolder: target, jobs: migration.jobs, pendingPreviousFolder: old)).write(to: historyURL, options: .atomic)
            jobs = migration.jobs
            savedFolder = target
            pendingPreviousFolder = old
            try await Task.detached(priority: .userInitiated) { try migration.finish() }.value
            try JSONEncoder().encode(LibrarySnapshot(savedFolder: target, jobs: jobs)).write(to: historyURL, options: .atomic)
            pendingPreviousFolder = nil
        } catch { self.error = "Could not move saved files: \(error.localizedDescription)" }
    }
    func refreshModels() {
        downloaded = Set(TranscriptionModel.catalog.filter {
            let path = modelsFolder.appendingPathComponent($0.filename)
            let size = (try? FileManager.default.attributesOfItem(atPath: path.path)[.size] as? NSNumber)?.int64Value
            return size == $0.bytes
        }.map(\.id))
    }
    func chooseFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true; panel.canChooseDirectories = false
        panel.allowedContentTypes = MediaInput.extensions.compactMap { UTType(filenameExtension: $0) }
        panel.begin { [weak self] result in
            if result == .OK { Task { @MainActor in self?.addFiles(panel.urls) } }
        }
    }
    func addFiles(_ urls: [URL]) {
        guard libraryReadable, !movingSavedFiles else { return }
        var unsupported = 0
        for url in urls {
            guard url.isFileURL, MediaInput.extensions.contains(url.pathExtension.lowercased()),
                  FileManager.default.isReadableFile(atPath: url.path) else { unsupported += 1; continue }
            let normalized = url.standardizedFileURL
            guard !jobs.contains(where: { $0.source == normalized && ($0.status == .queued || $0.status.isActive) }) else { continue }
            let job = TranscriptionJob(source: normalized)
            jobs.insert(job, at: 0); selection = job.id
        }
        if unsupported > 0 { error = "\(unsupported) item(s) could not be added. Choose readable audio or video files." }
        save()
    }
    /// Inserts a finished note at the top of the library and selects it.
    func addNote(_ job: TranscriptionJob) {
        var job = job
        do { try SavedLibrary.archive(job, in: job.source) }
        catch {
            let message = "The transcript could not be exported to the saved folder: \(error.localizedDescription)"
            job.error = [job.error, message].compactMap { $0 }.joined(separator: "\n")
            self.error = message
        }
        jobs.insert(job, at: 0)
        selection = job.id
        save()
    }
    func transcriptText(_ job: TranscriptionJob) -> String {
        job.resolvedKind == .note ? TranscriptOutput.labeledText(job.segments) : job.transcript
    }
    func addYouTube(_ text: String) {
        guard libraryReadable, !importing, !movingSavedFiles else { return }
        guard let url = MediaInput.youtubeURL(text) else { error = "Enter a youtube.com or youtu.be video or playlist link."; return }
        importing = true; showLink = false
        importWork = Task {
            defer { importing = false; importWork = nil }
            do {
                let result = try await CommandRunner().run(tool("yt-dlp"), ["--ignore-config", "--flat-playlist", "--dump-single-json", "--skip-download", "--no-warnings", "--socket-timeout", "20", "--", url.absoluteString])
                guard result.status == 0 else { throw AppFailure(cleanError(result.stderr, fallback: "Could not load this YouTube link.")) }
                let json = try JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [String: Any]
                let entries = json?["entries"] as? [[String: Any]] ?? json.map { [$0] } ?? []
                var added: [TranscriptionJob] = []
                for entry in entries {
                    guard let id = entry["id"] as? String, !id.isEmpty,
                          id.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-") }),
                          let source = URL(string: "https://www.youtube.com/watch?v=\(id)") else { continue }
                    if jobs.contains(where: { $0.source == source && ($0.status == .queued || $0.status.isActive) }) { continue }
                    var job = TranscriptionJob(source: source, title: entry["title"] as? String ?? "YouTube video", isRemote: true)
                    job.duration = entry["duration"] as? Double
                    added.append(job)
                }
                guard !added.isEmpty else { throw AppFailure("No new videos were found. They may already be queued, private or unavailable.") }
                jobs.insert(contentsOf: added, at: 0); selection = added.first?.id; save()
            } catch is CancellationError {} catch { self.error = error.localizedDescription }
        }
    }
    func cancelImport() { importWork?.cancel() }
    func cleanError(_ text: String, fallback: String) -> String {
        let lines = text.components(separatedBy: .newlines).filter { $0.contains("ERROR") || $0.lowercased().contains("error:") }
        return String((lines.isEmpty ? fallback : lines.joined(separator: "\n")).suffix(1500))
    }
    func update(_ id: UUID, _ block: (inout TranscriptionJob) -> Void) {
        if let index = jobs.firstIndex(where: { $0.id == id }) { block(&jobs[index]) }
    }
    func retry(_ id: UUID) { guard !movingSavedFiles else { return }; update(id) { $0.status = .queued; $0.error = nil }; save() }
    func remove(_ id: UUID) {
        guard !movingSavedFiles, let job = jobs.first(where: { $0.id == id }), !job.status.isActive else { return }
        jobs.removeAll { $0.id == id }
        if selection == id { selection = jobs.first?.id }
        save()
    }
    func cancel() { work?.cancel() }
    func cancelAll() { work?.cancel(); importWork?.cancel(); modelWork?.cancel() }
    func start() {
        guard libraryReadable, !busy, !movingSavedFiles, downloadingModel == nil, queuedCount > 0 else { return }
        let chosenModel = model, chosenLanguage = language
        let chosenBoost = audioBoostEnabled()
        let ids = jobs.filter { $0.status == .queued }.map(\.id)
        busy = true; diagnostics = ""; progress = 0
        work = Task {
            defer { busy = false; status = "Ready"; progress = 0; work = nil; save() }
            do {
                let modelURL = try await ensureModel(chosenModel)
                for id in ids {
                    try Task.checkCancellation()
                    guard let job = jobs.first(where: { $0.id == id && $0.status == .queued }) else { continue }
                    selection = id
                    do { try await transcribe(job, modelURL: modelURL, modelName: chosenModel.name, language: chosenLanguage, audioBoost: chosenBoost) }
                    catch is CancellationError { update(id) { $0.status = .cancelled }; throw CancellationError() }
                    catch { update(id) { $0.status = .failed; $0.error = error.localizedDescription }; save() }
                }
            } catch is CancellationError {} catch { self.error = error.localizedDescription }
        }
    }
    func downloadModel(_ model: TranscriptionModel) {
        guard downloadingModel == nil, !busy else { return }
        modelWork = Task {
            defer { modelWork = nil }
            do { _ = try await ensureModel(model) }
            catch is CancellationError {} catch { self.error = error.localizedDescription }
        }
    }
    func cancelModelDownload() { modelWork?.cancel(); if busy { work?.cancel() } }
    func deleteModel(_ model: TranscriptionModel) {
        guard !busy, downloadingModel == nil else { return }
        do { try FileManager.default.removeItem(at: modelsFolder.appendingPathComponent(model.filename)); refreshModels() }
        catch { self.error = error.localizedDescription }
    }
    func ensureModel(_ model: TranscriptionModel) async throws -> URL {
        let target = modelsFolder.appendingPathComponent(model.filename)
        downloadingModel = model.id; modelProgress = 0
        defer { downloadingModel = nil; refreshModels() }
        if downloaded.contains(model.id) {
            status = "Checking \(model.name)"
            let hash = try await Task.detached { try sha256File(target) }.value
            try Task.checkCancellation()
            if hash == model.sha256 { return target }
            try FileManager.default.removeItem(at: target)
            downloaded.remove(model.id)
        }
        status = "Downloading \(model.name)"
        let transfer = ModelTransfer { [weak self] fraction in
            Task { @MainActor in self?.modelProgress = fraction }
        }
        let temporary = try await transfer.download(model.url)
        defer { try? FileManager.default.removeItem(at: temporary) }
        status = "Checking \(model.name)"
        let hash = try await Task.detached { try sha256File(temporary) }.value
        try Task.checkCancellation()
        guard hash == model.sha256 else { throw AppFailure("Model verification failed. The file was not installed. Please download it again.") }
        if FileManager.default.fileExists(atPath: target.path) { try FileManager.default.removeItem(at: target) }
        try FileManager.default.moveItem(at: temporary, to: target)
        return target
    }
    func log(_ text: String) { diagnostics = String((diagnostics + text).suffix(30000)) }
    func transcribe(_ job: TranscriptionJob, modelURL: URL, modelName: String, language: String, audioBoost: Bool = true) async throws {
        let temp = root.appendingPathComponent("Work/\(job.id.uuidString)")
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temp) }
        var source = job.source
        if job.isRemote {
            status = "Downloading audio"; update(job.id) { $0.status = .downloading }; save()
            let result = try await runner.run(tool("yt-dlp"), ["--ignore-config", "--no-playlist", "--no-simulate", "--newline", "--socket-timeout", "30", "--retries", "2", "--js-runtimes", "deno:\(try tool("deno").path)", "-f", "bestaudio/best", "-o", temp.appendingPathComponent("source.%(ext)s").path, "--print", "after_move:filepath", "--", job.source.absoluteString], progress: log)
            log(result.stderr)
            guard result.status == 0 else { throw AppFailure(cleanError(result.stderr, fallback: "YouTube download failed. The video may require login or be unavailable.")) }
            guard let path = result.stdout.components(separatedBy: .newlines).last(where: { $0.hasPrefix(temp.path + "/source.") }), FileManager.default.fileExists(atPath: path) else { throw AppFailure("YouTube did not return an audio file.") }
            source = URL(fileURLWithPath: path)
        }
        try Task.checkCancellation()
        status = "Preparing audio"; progress = 0; update(job.id) { $0.status = .converting }; save()
        let audio = temp.appendingPathComponent("audio.wav")
        let conversion = try await runner.run(tool("ffmpeg"), ["-nostdin", "-hide_banner", "-loglevel", "error", "-y", "-i", source.path, "-vn", "-ar", "16000", "-ac", "1", "-c:a", "pcm_s16le", audio.path], progress: log)
        guard conversion.status == 0 else { log(conversion.stderr); throw AppFailure("Could not read the audio in this file. It may be damaged or use an unsupported codec.") }
        var inferenceAudio = audio
        var speech: [SpeechRange]?
        var warning: String?
        if audioBoost {
            do { speech = try await SpeechActivityDetector.ranges(file: audio, executable: tool("whisper-vad-speech-segments")) }
            catch is CancellationError { throw CancellationError() }
            catch { warning = "The silence check was unavailable. Short closing phrases may need review." }
            if let activity = speech {
                let destination = temp.appendingPathComponent("prepared.wav")
                let preparation = Task.detached(priority: .userInitiated) { try AudioPreparation.boostFile(at: audio, to: destination, speech: activity) }
                let report = try await withTaskCancellationHandler { try await preparation.value } onCancel: { preparation.cancel() }
                log("\nQuiet audio boost: \(report.boostedBlocks)/\(report.blocks) blocks, \(report.samples) samples preserved.\n")
                inferenceAudio = destination
            }
        }
        status = "Transcribing with \(modelName)"; update(job.id) { $0.status = .transcribing; $0.modelName = modelName }; save()
        let output = temp.appendingPathComponent("transcript")
        let arguments = ["--model", modelURL.path, "--file", inferenceAudio.path, "--language", language, "--output-json", "--output-txt", "--output-file", output.path, "--print-progress", "--threads", String(min(6, max(2, ProcessInfo.processInfo.activeProcessorCount - 2))) ]
        var result = try await runner.run(tool("whisper-cli"), arguments) { [weak self] text in
            self?.log(text)
            // A chunk can hold several updates; the last one is the current value.
            if let range = text.ranges(of: #/progress =\s*\d+/#).last {
                let value = text[range].filter(\.isNumber)
                self?.progress = min(1, Double(value).map { $0 / 100 } ?? 0)
            }
        }
        log(result.stderr)
        if result.status != 0 {
            try Task.checkCancellation()
            status = "Retrying on CPU"
            log("\nMetal attempt failed. Retrying with CPU.\n")
            result = try await runner.run(tool("whisper-cli"), arguments + ["--no-gpu"], progress: log)
            log(result.stderr)
        }
        guard result.status == 0 else { throw AppFailure("Transcription failed on both GPU and CPU. Try a smaller model or check the activity log.") }
        var segments = try TranscriptOutput.parseWhisper(Data(contentsOf: output.appendingPathExtension("json")))
        let firstText = segments.map(\.text).joined(separator: " ")
        if RepetitionGuard.score(firstText) > 0 {
            status = "Checking a repeated passage"
            log("\nSustained repetition detected. Retrying original audio without previous text context.\n")
            var retryArguments = arguments
            if let fileIndex = retryArguments.firstIndex(of: "--file") { retryArguments[fileIndex + 1] = audio.path }
            retryArguments += ["--max-context", "0"]
            do {
                let retry = try await runner.run(tool("whisper-cli"), retryArguments, progress: log)
                guard retry.status == 0 else { throw AppFailure("The repeated passage could not be checked.") }
                let candidate = try TranscriptOutput.parseWhisper(Data(contentsOf: output.appendingPathExtension("json")))
                if RepetitionGuard.prefers(candidate.map(\.text).joined(separator: " "), over: firstText) { segments = candidate }
            } catch is CancellationError { throw CancellationError() }
            catch { warning = "A repeated passage could not be checked. Review this transcript." }
            if RepetitionGuard.score(segments.map(\.text).joined(separator: " ")) > 0 {
                warning = "Some passages contain repeated text and need review."
            }
        }
        if SilenceGuard.needsCheck(segments) {
            do {
                let activity: [SpeechRange]
                if let speech { activity = speech }
                else { activity = try await SpeechActivityDetector.ranges(file: audio, executable: tool("whisper-vad-speech-segments")) }
                segments = SilenceGuard.filter(segments, speech: activity)
            } catch is CancellationError { throw CancellationError() }
            catch { warning = "The silence check was unavailable. Short closing phrases may need review." }
        }
        segments = HallucinationFilter.clean(segments, removeNeighborRepeats: false, preserveShortClosings: true)
        let transcript = segments.map(\.text).joined(separator: "\n")
        let archive = outputFolder.appendingPathComponent(job.id.uuidString)
        try FileManager.default.createDirectory(at: archive, withIntermediateDirectories: true)
        try transcript.write(to: archive.appendingPathComponent("transcript.txt"), atomically: true, encoding: .utf8)
        try TranscriptOutput.subtitles(segments, vtt: false).write(to: archive.appendingPathComponent("transcript.srt"), atomically: true, encoding: .utf8)
        try TranscriptOutput.subtitles(segments, vtt: true).write(to: archive.appendingPathComponent("transcript.vtt"), atomically: true, encoding: .utf8)
        update(job.id) { $0.status = .completed; $0.transcript = transcript; $0.segments = segments; $0.error = warning }
        progress = 1; save()
    }
    func copyTranscript() {
        guard let job = current else { return }
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(transcriptText(job), forType: .string)
    }
    func export(_ ext: String) {
        guard let job = current else { return }
        let text = ext == "txt" ? transcriptText(job) : TranscriptOutput.subtitles(job.segments, vtt: ext == "vtt")
        let panel = NSSavePanel()
        panel.directoryURL = outputFolder
        panel.nameFieldStringValue = job.title.replacingOccurrences(of: "/", with: "-") + "." + ext
        panel.allowedContentTypes = ext == "txt" ? [.plainText] : [UTType(filenameExtension: ext, conformingTo: .text) ?? .plainText]
        panel.begin { [weak self] result in
            guard result == .OK, let url = panel.url else { return }
            do { try text.write(to: url, atomically: true, encoding: .utf8) }
            catch { Task { @MainActor in self?.error = error.localizedDescription } }
        }
    }
}
