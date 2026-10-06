import Foundation
import WhisperDropCore

/// Records a meeting or lecture and transcribes it while it records.
///
/// Parakeet notes stream. Each source's audio grows in a `RollingAudio`, `LiveText` decodes short windows of it,
/// and every settled word joins the transcript, one sentence per paragraph, with no time limit. Whisper (legacy)
/// notes cut the audio into chunks at pauses, at most 60 seconds long, and transcribe each chunk.
@MainActor
final class NoteRecorder: ObservableObject {
    enum State: Equatable { case idle, starting, recording, paused, finishing, failed(String) }
    @Published private(set) var state: State = .idle
    @Published private(set) var sources: NoteSources = .both
    /// Recorded seconds. Paused time does not count.
    @Published private(set) var elapsed: Double = 0
    /// Live merged transcript so far.
    @Published private(set) var segments: [TranscriptSegment] = []
    @Published private(set) var micLevel: Float = 0
    @Published private(set) var systemLevel: Float = 0
    /// Chunks recorded but not transcribed yet.
    @Published private(set) var pendingChunks = 0
    @Published var title = ""
    /// Shown while recording continues after a source or a chunk fails.
    @Published private(set) var warning: String?
    @Published var showLanguageReminder = false
    @Published private(set) var sessionLanguage = "auto"
    /// True for Parakeet notes, which are decoded as the audio grows instead of in chunks.
    @Published private(set) var streaming = false
    /// Recorded seconds not settled yet, in the stream furthest behind. About six while streaming keeps up.
    @Published private(set) var lagSeconds: Double = 0
    /// Words heard after the last settled word. They can still change.
    @Published private(set) var livePreview: [NoteLivePreview] = []
    private var liveText: [NoteStream: LiveText] = [:]
    private var streamAudio: [NoteStream: RollingAudio] = [:]
    private var sentences: [NoteStream: SentenceParagraphs] = [:]
    /// Recorded seconds before the current stretch of recording.
    private var activeBefore: Double = 0
    private var pauseCount = 0
    private var pendingStart: NoteSources?
    private var sessionVocabulary = ""
    private var sessionKeepAudio = true
    private var sessionAudioBoost = true

    private let settings: AppSettings
    private let host: ModelHost
    private let folder: URL
    private let folderProvider: (() -> (audio: URL, transcripts: URL))?
    var canStartRecording: () -> Bool = { true }
    /// True when the model's files are installed. A note never starts with a model it cannot load.
    var modelInstalled: (TranscriptionModel) -> Bool = { _ in true }
    private let onFinish: (TranscriptionJob) -> Void
    private let captures: NoteCaptureFactory
    private let defaults: UserDefaults
    private let clock = ContinuousClock()
    private let wake = NoteWake()

    private var microphone: (any NoteCaptureSource)?
    private var systemTap: (any NoteCaptureSource)?
    private var youWriter: AudioFileWriter?
    private var othersWriter: AudioFileWriter?
    private let micPending = NoteSampleBuffer()
    private let systemPending = NoteSampleBuffer()
    private var micChunker = Chunker.lecture
    private var systemChunker = Chunker.lecture
    private var transcript = NoteTranscriptState()
    private var queue: [NoteQueuedChunk] = []
    private var nextSequence = 0
    private var inFlight = false
    private var sawSpeech = false
    private var confirmedSystemAudio = false
    private var labelingSpeakers = false
    private var microphoneActive = false
    private var systemActive = false
    private var noteFolder: URL?
    private var noteTranscriptFolder: URL?
    private var lease: UUID?
    private var sessionModel: TranscriptionModel?
    private var startedAt: ContinuousClock.Instant?
    private var recordedAt = Date()
    private var lastPartialSave: ContinuousClock.Instant?
    private var tickerTask: Task<Void, Never>?
    private var sessionTask: Task<Void, Never>?
    private var transcribeTask: Task<ServerTranscription, Error>?
    private var generation = 0
    private var stopRequested = false
    private var discardRequested = false
    private var didFlushChunkers = false
    private var didFinish = false
    private var captureStarted = false
    private var terminationHandoff = false
    private var captureWarning: String?
    private var transcriptionWarning: String?
    private var failedChunkCount = 0

    /// - Parameters:
    ///   - folder: where recordings are written (one subfolder per note).
    ///   - onFinish: receives the completed job (kind `.note`, status `.completed`) to add to the library.
    ///   - captures: replaces the real devices in tests. Production uses `.live`.
    init(settings: AppSettings, host: ModelHost, folder: URL, onFinish: @escaping (TranscriptionJob) -> Void,
         captures: NoteCaptureFactory = .live, defaults: UserDefaults = .standard,
         folderProvider: (() -> (audio: URL, transcripts: URL))? = nil) {
        self.settings = settings
        self.host = host
        self.folder = folder
        self.folderProvider = folderProvider
        self.onFinish = onFinish
        self.captures = captures
        self.defaults = defaults
    }

    func requestStart(_ sources: NoteSources) {
        guard state == .idle else { return }
        if !defaults.bool(forKey: "noteLanguageReminderSeen") {
            pendingStart = sources
            showLanguageReminder = true
        } else { start(sources) }
    }

    func confirmStart() {
        guard let sources = pendingStart else { return }
        pendingStart = nil
        showLanguageReminder = false
        defaults.set(true, forKey: "noteLanguageReminderSeen")
        start(sources)
    }

    func cancelStart() { pendingStart = nil; showLanguageReminder = false }

    func dismissFailure() {
        guard case .failed = state else { return }
        resetFields()
        state = .idle
    }

    func start(_ sources: NoteSources) {
        guard state == .idle, canStartRecording() else { return }
        let model = settings.model(for: .notes)
        guard model.supports(language: settings.noteLanguage) else {
            state = .failed("\(model.name) does not transcribe \(LiveFormat.language(settings.noteLanguage)). Download a legacy Whisper model in Settings, Models.")
            return
        }
        guard modelInstalled(model) else {
            state = .failed("Download \(model.name) in Settings, Models before recording a note.")
            return
        }
        sessionModel = model
        streaming = model.engine == .parakeet
        sessionLanguage = settings.noteLanguage
        settings.nextNoteLanguage = nil
        sessionVocabulary = settings.noteVocabulary
        sessionKeepAudio = settings.keepNoteAudio
        sessionAudioBoost = settings.automaticAudioBoost
        generation += 1
        let token = generation
        self.sources = sources
        state = .starting
        warning = nil
        stopRequested = false
        discardRequested = false
        didFinish = false
        captureStarted = false
        terminationHandoff = false
        sessionTask = Task { [weak self] in
            await self?.runSession(token: token, sources: sources)
        }
    }

    /// Stops capture and transcribes what was recorded so far. Recording continues in the same note on `resume`.
    /// While paused the model can unload according to the idle setting.
    func pause() {
        guard state == .recording else { return }
        updateElapsed()
        activeBefore = elapsed
        startedAt = nil
        state = .paused
        pauseCount += 1
        haltCapture()
        drainPendingAudio(flush: true)
        micLevel = 0
        systemLevel = 0
        wake.signal()
    }

    /// Restarts the sources that were recording, appending to the same audio files and transcript.
    func resume() {
        guard state == .paused, let model = sessionModel else { return }
        var errors: [String] = []
        if microphoneActive, let writer = youWriter {
            do { microphone = try startSource(system: false, writer: writer) } catch { errors.append(error.localizedDescription) }
        }
        if systemActive, let writer = othersWriter {
            do { systemTap = try startSource(system: true, writer: writer) } catch { errors.append(error.localizedDescription) }
        }
        let detail = errors.filter { !$0.isEmpty }.joined(separator: " ")
        guard microphone != nil || systemTap != nil else {
            captureWarning = "Recording could not resume. \(detail)".trimmingCharacters(in: .whitespaces)
            publishWarning()
            return
        }
        if !errors.isEmpty {
            captureWarning = "\(microphone == nil ? "The microphone" : "System audio") did not resume. \(detail)".trimmingCharacters(in: .whitespaces)
            publishWarning()
        }
        if lease == nil { lease = host.acquireLease() }
        host.prewarm(model)
        didFlushChunkers = false
        startedAt = clock.now
        state = .recording
    }

    /// Stops capture, transcribes remaining audio, then calls `onFinish`.
    func stop() {
        guard state == .starting || state == .recording || state == .paused else { return }
        updateElapsed()
        state = .finishing
        stopRequested = true
        haltCapture()
        drainPendingAudio(flush: true)
        wake.signal()
    }

    /// Stops and discards the recording.
    func discard() {
        guard state != .idle else { return }
        generation += 1
        discardRequested = true
        stopRequested = true
        haltCapture()
        transcribeTask?.cancel()
        sessionTask?.cancel()
        wake.finish()
        tickerTask?.cancel()
        tickerTask = nil
        closeWriters()
        removeNoteFolder()
        releaseModel()
        resetFields()
        state = .idle
    }

    /// App is quitting. Stops capture and closes the audio files without deleting them.
    /// Also flushes the chunkers and wakes the transcription loop so a run loop that is still
    /// spinning can finish the note. This method does not wait for that loop.
    func finishForTermination() {
        terminationHandoff = true
        if state == .starting || state == .recording || state == .paused {
            updateElapsed()
            state = .finishing
            stopRequested = true
        }
        haltCapture()
        drainPendingAudio(flush: true)
        closeWriters()
        tickerTask?.cancel()
        tickerTask = nil
        writePartialTranscript()
        wake.signal()
    }

    private func runSession(token: Int, sources: NoteSources) async {
        if sources.usesMicrophone {
            let allowed = await captures.requestMicrophoneAccess()
            guard token == generation, !discardRequested else { return }
            if stopRequested {
                await finishIfNeeded(token: token)
                return
            }
            guard allowed else {
                state = .failed(NoteCopy.microphoneDenied)
                return
            }
        }
        guard token == generation, !discardRequested else { return }
        if stopRequested {
            await finishIfNeeded(token: token)
            return
        }

        guard let model = sessionModel else { return }
        lease = host.acquireLease()
        host.prewarm(model)

        do {
            noteFolder = try makeNoteFolder()
        } catch {
            guard token == generation, !discardRequested else { return }
            releaseModel()
            state = .failed(NoteCopy.couldNotCreateFolder)
            return
        }
        guard token == generation, !discardRequested else { return }
        if stopRequested {
            await finishIfNeeded(token: token)
            return
        }

        switch startCaptures(token: token, sources: sources) {
        case .aborted:
            await finishIfNeeded(token: token)
            return
        case .failed(let message):
            guard token == generation, !discardRequested else { return }
            haltCapture()
            closeWriters()
            removeNoteFolder()
            releaseModel()
            resetFields()
            state = .failed(message)
            return
        case .ready(let partialWarning):
            captureWarning = partialWarning
            publishWarning()
        }

        guard token == generation, !discardRequested else { return }
        recordedAt = Date()
        startedAt = clock.now
        lastPartialSave = startedAt
        state = .recording
        startTicker()
        if stopRequested {
            haltCapture()
            drainPendingAudio(flush: true)
        }
        if streaming { await streamUntilStopped(token: token) } else { await processUntilStopped(token: token) }
        await finishIfNeeded(token: token)
    }

    private func makeNoteFolder() throws -> URL {
        let roots = folderProvider?() ?? (audio: folder, transcripts: folder)
        let id = UUID().uuidString
        let note = roots.audio.appendingPathComponent(id, isDirectory: true)
        let transcript = roots.transcripts.appendingPathComponent(id, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: note, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: transcript, withIntermediateDirectories: true)
        } catch {
            try? FileManager.default.removeItem(at: note)
            throw error
        }
        noteTranscriptFolder = transcript
        return note
    }

    private func startCaptures(token: Int, sources: NoteSources) -> CaptureOutcome {
        guard let noteFolder else { return .failed(NoteCopy.couldNotStart) }
        var errors: [String] = []
        if sources.usesMicrophone {
            switch openCapture(token: token, file: NoteCopy.microphoneFile, in: noteFolder, system: false) {
            case .started:
                microphoneActive = true
                captureStarted = true
            case .failed(let message):
                errors.append(message)
            case .aborted:
                return .aborted
            }
        }
        if token != generation || discardRequested || stopRequested {
            return .aborted
        }
        // The microphone starts first so this process is already a HAL client when the tap is created.
        if sources.usesSystemAudio {
            switch openCapture(token: token, file: NoteCopy.systemFile, in: noteFolder, system: true) {
            case .started:
                systemActive = true
                captureStarted = true
            case .failed(let message):
                errors.append(message)
            case .aborted:
                return .aborted
            }
        }
        labelingSpeakers = microphoneActive && systemActive
        transcript.labelingSpeakers = labelingSpeakers
        guard microphoneActive || systemActive else {
            let detail = errors.filter { !$0.isEmpty }.joined(separator: " ")
            return .failed(detail.isEmpty ? NoteCopy.couldNotStart : detail)
        }
        return .ready(warning: partialWarning(errors: errors))
    }

    private func partialWarning(errors: [String]) -> String? {
        guard !errors.isEmpty else { return nil }
        let detail = errors.joined(separator: " ")
        if microphoneActive && !systemActive {
            return "System audio is not being recorded. \(detail)"
        }
        if systemActive && !microphoneActive {
            return "The microphone is not being recorded. \(detail)"
        }
        return nil
    }

    private func openCapture(token: Int, file: String, in folder: URL, system: Bool) -> OpenResult {
        if system && !captures.systemAudioSupported() {
            return .failed(NoteCopy.systemAudioUnavailable)
        }
        let url = folder.appendingPathComponent(file)
        let writer: AudioFileWriter
        do {
            writer = try captures.makeWriter(url)
        } catch {
            return .failed(error.localizedDescription)
        }
        do {
            let source = try startSource(system: system, writer: writer)
            guard token == generation, !discardRequested, !stopRequested else {
                source.stop()
                writer.close()
                return .aborted
            }
            if system {
                systemTap = source
                othersWriter = writer
            } else {
                microphone = source
                youWriter = writer
            }
            return .started
        } catch {
            writer.close()
            try? FileManager.default.removeItem(at: url)
            return .failed(error.localizedDescription)
        }
    }

    /// Starts one source writing to `writer` and to the samples the recorder drains.
    private func startSource(system: Bool, writer: AudioFileWriter) throws -> any NoteCaptureSource {
        if system && !captures.systemAudioSupported() { throw NoteCaptureError.unsupportedSystemAudio }
        let pending = system ? systemPending : micPending
        let source = system ? captures.makeSystemTap() : captures.makeMicrophone()
        source.onSamples = { samples in
            writer.append(samples)
            pending.append(samples)
        }
        source.onLevel = { level in pending.setLevel(level) }
        do {
            try source.start()
        } catch {
            source.onSamples = nil
            source.onLevel = nil
            throw error
        }
        return source
    }

    private func startTicker() {
        tickerTask?.cancel()
        tickerTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(500))
                guard !Task.isCancelled else { return }
                self?.tick()
            }
        }
    }

    private func tick() {
        guard state == .recording || state == .paused || state == .finishing else { return }
        updateElapsed()
        checkCaptureHealth()
        drainPendingAudio(flush: false)
        savePartialIfDue()
    }

    private func publishPreview() {
        guard settings.noteLiveText else {
            livePreview = []
            return
        }
        livePreview = [NoteStream.microphone, .system].compactMap { stream in
            let text = LiveText.join(liveText[stream]?.pending ?? [])
            guard !text.isEmpty else { return nil }
            return NoteLivePreview(speaker: NoteSpeakers.label(stream: stream, bothLive: labelingSpeakers), text: text)
        }
    }

    private func updateElapsed() {
        guard !stopRequested else { return }
        elapsed = activeBefore + (startedAt.map { NoteClock.seconds(clock.now - $0) } ?? 0)
    }

    private func drainPendingAudio(flush: Bool) {
        let mic = micPending.drain()
        if let level = mic.level { micLevel = level }
        if !mic.samples.isEmpty { take(mic.samples, stream: .microphone) }
        let system = systemPending.drain()
        if let level = system.level { systemLevel = level }
        if !system.samples.isEmpty {
            if !confirmedSystemAudio && NoteAudio.containsAudibleSignal(system.samples) {
                confirmedSystemAudio = true
                defaults.set(true, forKey: NoteCopy.systemAudioConfirmedKey)
            }
            take(system.samples, stream: .system)
        }
        guard flush, !streaming, !didFlushChunkers else { return }
        didFlushChunkers = true
        if let tail = micChunker.flush() { enqueue([tail], stream: .microphone) }
        if let tail = systemChunker.flush() { enqueue([tail], stream: .system) }
    }

    private func take(_ samples: [Float], stream: NoteStream) {
        if streaming {
            streamAudio[stream, default: RollingAudio()].append(samples)
        } else if stream == .microphone {
            enqueue(micChunker.append(samples), stream: stream)
        } else {
            enqueue(systemChunker.append(samples), stream: stream)
        }
    }

    private func enqueue(_ chunks: [AudioChunk], stream: NoteStream) {
        var added = false
        for chunk in chunks where chunk.hasSpeech && !chunk.samples.isEmpty {
            sawSpeech = true
            queue.append(NoteQueuedChunk(sequence: nextSequence, stream: stream, chunk: chunk))
            nextSequence += 1
            added = true
        }
        publishPending()
        if added { wake.signal() }
    }

    private func publishPending() {
        pendingChunks = queue.count + (inFlight ? 1 : 0)
    }

    private func processUntilStopped(token: Int) async {
        let stream = wake.open()
        var iterator = stream.makeAsyncIterator()
        while token == generation && !discardRequested {
            while token == generation && !discardRequested, let item = NoteQueue.popNext(&queue) {
                inFlight = true
                publishPending()
                await transcribe(item, token: token)
                inFlight = false
                publishPending()
            }
            if token != generation || discardRequested || stopRequested { return }
            // Everything recorded before the pause is transcribed. The model may unload until recording resumes.
            if state == .paused { releaseModel() }
            if await iterator.next() == nil { return }
        }
    }

    // MARK: Streaming

    /// Decodes each source's newest audio about every 1.5 seconds until the note stops. Each pause first
    /// settles every word recorded so far, then lets the model unload while nothing is recorded.
    private func streamUntilStopped(token: Int) async {
        var settledPauses = 0
        while token == generation, !discardRequested, !stopRequested {
            let began = clock.now
            if state == .paused {
                if settledPauses != pauseCount {
                    settledPauses = pauseCount
                    await streamStep(token: token, final: true)
                    if state == .paused { releaseModel() }
                }
            } else {
                await streamStep(token: token, final: false)
            }
            let wait = 1.5 - NoteClock.seconds(clock.now - began)
            if wait > 0 { try? await Task.sleep(for: .seconds(wait)) }
        }
    }

    /// One request per source. A final step repeats until every word recorded so far is settled.
    private func streamStep(token: Int, final: Bool) async {
        guard let model = sessionModel else { return }
        let language = NoteLanguage.requestCode(setting: sessionLanguage, pinned: nil)
        for stream in [NoteStream.microphone, .system] {
            // A final step covers the audio recorded when it began, even if recording resumes meanwhile.
            guard let end = streamAudio[stream]?.end else { continue }
            while token == generation, !discardRequested, let audio = streamAudio[stream] {
                var live = liveText[stream] ?? LiveText(start: audio.start)
                guard let window = live.window(audioStart: audio.start, end: end), let chunk = audio.audio(window) else { break }
                var words: [TranscriptWord] = []
                if chunk.hasSpeech {
                    sawSpeech = true
                    do {
                        words = try await decode(chunk, model: model, language: language, stream: stream, attempts: final ? 2 : 1)
                    } catch {
                        guard token == generation, !discardRequested, !Task.isCancelled else { return }
                        // A short window is tried again with more audio. A full one is skipped so the note keeps up.
                        if !final, window.upperBound - window.lowerBound < live.maxWindow - 0.5 { break }
                        noteChunkFailure()
                    }
                    guard token == generation, !discardRequested else { return }
                }
                live.accept(words, window: window, final: final && window.upperBound >= end)
                commit(live.takeSettled(), stream: stream)
                liveText[stream] = live
                streamAudio[stream]?.discard(before: live.settledUntil - live.leftContext - 1)
                publishPreview()
                if !final || live.settledUntil >= end { break }
            }
        }
        lagSeconds = [NoteStream.microphone, .system].compactMap { stream in
            streamAudio[stream].map { $0.end - (liveText[stream]?.settledUntil ?? $0.start) }
        }.max() ?? 0
    }

    private func decode(_ chunk: AudioChunk, model: TranscriptionModel, language: String, stream: NoteStream,
                        attempts: Int) async throws -> [TranscriptWord] {
        let speaker = NoteSpeakers.label(stream: stream, bothLive: labelingSpeakers)
        let boost = sessionAudioBoost
        var attempt = 1
        while true {
            let task = Task { @MainActor in
                try await self.host.transcribe(chunk.samples, model: model, language: language, offset: chunk.start, speaker: speaker,
                                               checkSilence: false, boostQuietAudio: boost)
            }
            transcribeTask = task
            do {
                let result = try await task.value
                transcribeTask = nil
                if let message = host.speechCheckWarning { transcriptionWarning = message; publishWarning() }
                return result.timedWords
            } catch {
                transcribeTask = nil
                if attempt >= attempts || Task.isCancelled || error is CancellationError { throw error }
                attempt += 1
            }
        }
    }

    private func commit(_ words: [TranscriptWord], stream: NoteStream) {
        guard !words.isEmpty else { return }
        let speaker = NoteSpeakers.label(stream: stream, bothLive: labelingSpeakers)
        sentences[stream, default: SentenceParagraphs(speaker: speaker)].append(words)
        let mic = sentences[.microphone]?.segments ?? [], system = sentences[.system]?.segments ?? []
        segments = labelingSpeakers ? TranscriptMerger.merge(you: mic, others: system) : NoteJobs.renumber(mic + system)
    }

    // MARK: Chunks

    private func transcribe(_ item: NoteQueuedChunk, token: Int) async {
        let model = sessionModel ?? settings.model(for: .notes)
        let speaker = NoteSpeakers.label(stream: item.stream, bothLive: labelingSpeakers)
        let prompt = NotePrompt.prompt(previousText: transcript.text(for: item.stream), chunkDuration: item.chunk.duration, vocabulary: sessionVocabulary)
        let language = NoteLanguage.requestCode(setting: sessionLanguage, pinned: transcript.pinnedLanguage)
        let samples = item.chunk.samples
        let offset = item.chunk.start
        let task = Task { @MainActor in
            try Task.checkCancellation()
            return try await self.transcribeOnce(samples: samples, model: model, language: language, prompt: prompt, offset: offset, speaker: speaker)
        }
        transcribeTask = task
        let result: ServerTranscription
        do {
            result = try await task.value
        } catch {
            transcribeTask = nil
            guard token == generation, !discardRequested, !Task.isCancelled else { return }
            noteChunkFailure()
            return
        }
        transcribeTask = nil
        guard token == generation, !discardRequested else { return }
        if let message = host.speechCheckWarning { transcriptionWarning = message; publishWarning() }
        segments = transcript.accept(result, stream: item.stream, languageSetting: sessionLanguage, chunk: item.chunk)
    }

    private func transcribeOnce(samples: [Float], model: TranscriptionModel, language: String, prompt: String?, offset: Double, speaker: Speaker?) async throws -> ServerTranscription {
        do {
            return try await host.transcribe(samples, model: model, language: language, prompt: prompt, offset: offset, speaker: speaker, boostQuietAudio: sessionAudioBoost)
        } catch {
            if Task.isCancelled || error is CancellationError { throw error }
            return try await host.transcribe(samples, model: model, language: language, prompt: prompt, offset: offset, speaker: speaker, boostQuietAudio: sessionAudioBoost)
        }
    }

    private func noteChunkFailure() {
        failedChunkCount += 1
        transcriptionWarning = failedChunkCount == 1
            ? "A part of the recording could not be transcribed and was skipped."
            : "\(failedChunkCount) parts of the recording could not be transcribed and were skipped."
        publishWarning()
    }

    private func publishWarning() {
        let text = [captureWarning, transcriptionWarning].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "\n")
        warning = text.isEmpty ? nil : text
    }

    private func finishIfNeeded(token: Int) async {
        guard !didFinish else { return }
        didFinish = true
        guard token == generation, !discardRequested else { return }
        guard captureStarted, noteFolder != nil else {
            haltCapture()
            closeWriters()
            removeNoteFolder()
            releaseModel()
            resetFields()
            state = .idle
            return
        }
        updateElapsed()
        stopRequested = true
        state = .finishing
        haltCapture()
        drainPendingAudio(flush: true)
        if streaming { await streamStep(token: token, final: true) } else { await processUntilStopped(token: token) }
        guard token == generation, !discardRequested else { return }
        livePreview = []
        tickerTask?.cancel()
        tickerTask = nil
        updateElapsed()
        closeWriters()
        writePartialTranscript()
        let keepAudio = sessionKeepAudio || terminationHandoff
        if !keepAudio { deleteCapturedAudio() }
        let folder = noteFolder ?? self.folder
        let job = NoteJobs.make(
            folder: folder,
            transcriptFolder: noteTranscriptFolder,
            customTitle: title,
            recordedAt: recordedAt,
            segments: segments,
            modelName: (sessionModel ?? settings.model(for: .notes)).name,
            duration: elapsed,
            keepAudio: keepAudio,
            detectedSpeech: sawSpeech,
            transcriptionWarning: warning,
            sentenceParagraphs: streaming
        )
        releaseModel()
        // With Keep model ready, put dictation's own model back once the note's model is no longer needed.
        let dictationModel = settings.model(for: .dictation)
        if settings.keepReady, dictationModel.id != sessionModel?.id, modelInstalled(dictationModel) { host.prewarm(dictationModel) }
        resetFields()
        state = .idle
        onFinish(job)
    }

    private func savePartialIfDue() {
        guard let lastPartialSave else { return }
        guard NoteClock.seconds(clock.now - lastPartialSave) >= 30 else { return }
        self.lastPartialSave = clock.now
        writePartialTranscript()
    }

    private func writePartialTranscript() {
        guard let noteTranscriptFolder else { return }
        let url = noteTranscriptFolder.appendingPathComponent(NoteCopy.partialTranscriptFile)
        do { try JSONEncoder().encode(segments).write(to: url, options: .atomic) }
        catch {
            captureWarning = "The transcript could not be saved to your selected folder. Check access and disk space."
            publishWarning()
        }
    }

    private func deleteCapturedAudio() {
        guard let noteFolder else { return }
        for name in [NoteCopy.microphoneFile, NoteCopy.systemFile] {
            try? FileManager.default.removeItem(at: noteFolder.appendingPathComponent(name))
        }
        if noteFolder != noteTranscriptFolder, (try? FileManager.default.contentsOfDirectory(atPath: noteFolder.path).isEmpty) == true {
            try? FileManager.default.removeItem(at: noteFolder)
        }
    }

    private func haltCapture() {
        checkCaptureHealth()
        microphone?.stop()
        systemTap?.stop()
        checkCaptureHealth()
        microphone?.onSamples = nil
        microphone?.onLevel = nil
        microphone = nil
        systemTap?.onSamples = nil
        systemTap?.onLevel = nil
        systemTap = nil
    }

    private func closeWriters() {
        youWriter?.close()
        othersWriter?.close()
        checkCaptureHealth()
        youWriter = nil
        othersWriter = nil
    }

    private func checkCaptureHealth() {
        if (microphone?.droppedPacketCount ?? 0) + (systemTap?.droppedPacketCount ?? 0) > 0 {
            captureWarning = "Some audio was lost during capture. The transcript may have gaps."
        }
        if youWriter?.hasFailed == true || othersWriter?.hasFailed == true {
            captureWarning = "The recording could not be fully saved. Check available disk space."
        }
        publishWarning()
    }

    private func removeNoteFolder() {
        if let noteTranscriptFolder, noteTranscriptFolder != noteFolder {
            try? FileManager.default.removeItem(at: noteTranscriptFolder)
        }
        self.noteTranscriptFolder = nil
        guard let noteFolder else { return }
        try? FileManager.default.removeItem(at: noteFolder)
        self.noteFolder = nil
    }

    private func releaseModel() {
        if let lease {
            host.releaseLease(lease)
            self.lease = nil
        }
    }

    private func resetFields() {
        elapsed = 0
        segments = []
        streaming = false
        lagSeconds = 0
        liveText = [:]
        streamAudio = [:]
        sentences = [:]
        livePreview = []
        activeBefore = 0
        pauseCount = 0
        micLevel = 0
        systemLevel = 0
        pendingChunks = 0
        title = ""
        warning = nil
        transcript = NoteTranscriptState()
        queue = []
        nextSequence = 0
        inFlight = false
        sawSpeech = false
        confirmedSystemAudio = false
        labelingSpeakers = false
        microphoneActive = false
        systemActive = false
        sessionModel = nil
        startedAt = nil
        lastPartialSave = nil
        didFlushChunkers = false
        captureStarted = false
        captureWarning = nil
        transcriptionWarning = nil
        failedChunkCount = 0
        stopRequested = false
        discardRequested = false
        noteFolder = nil
        noteTranscriptFolder = nil
        micChunker = .lecture
        systemChunker = .lecture
        micPending.clear()
        systemPending.clear()
    }
}

/// Builds the capture objects NoteRecorder owns. Tests can substitute fakes.
protocol NoteCaptureSource: AnyObject {
    var onSamples: (@Sendable ([Float]) -> Void)? { get set }
    var onLevel: (@Sendable (Float) -> Void)? { get set }
    var droppedPacketCount: Int { get }
    func start() throws
    func stop()
}

struct NoteCaptureFactory {
    var makeMicrophone: () -> any NoteCaptureSource
    var makeSystemTap: () -> any NoteCaptureSource
    var makeWriter: (URL) throws -> AudioFileWriter
    var requestMicrophoneAccess: () async -> Bool
    var systemAudioSupported: () -> Bool

    static let live = NoteCaptureFactory(
        makeMicrophone: { MicCapture() },
        makeSystemTap: { SystemAudioTap() },
        makeWriter: { try AudioFileWriter(url: $0) },
        requestMicrophoneAccess: { await MicCapture.requestAccess() },
        systemAudioSupported: { SystemAudioTap.isSupported }
    )
}

/// Lock-protected samples and the latest level. Capture threads append; the main actor drains.
final class NoteSampleBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var samples: [Float] = []
    private var level: Float?

    func append(_ chunk: [Float]) {
        guard !chunk.isEmpty else { return }
        lock.lock()
        samples.append(contentsOf: chunk)
        lock.unlock()
    }

    func setLevel(_ value: Float) {
        lock.lock()
        level = value
        lock.unlock()
    }

    func drain() -> (samples: [Float], level: Float?) {
        lock.lock()
        let taken = samples
        let level = self.level
        samples.removeAll(keepingCapacity: true)
        lock.unlock()
        return (taken, level)
    }

    func clear() {
        lock.lock()
        samples.removeAll(keepingCapacity: false)
        level = nil
        lock.unlock()
    }
}

/// Single-consumer wake. `open` replaces the previous stream so a new session cannot see the old one.
final class NoteWake: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: AsyncStream<Void>.Continuation?

    func open() -> AsyncStream<Void> {
        let stream = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        lock.lock()
        continuation?.finish()
        continuation = stream.continuation
        lock.unlock()
        return stream.stream
    }

    func signal() {
        lock.lock()
        let continuation = continuation
        lock.unlock()
        continuation?.yield()
    }

    func finish() {
        lock.lock()
        let continuation = continuation
        self.continuation = nil
        lock.unlock()
        continuation?.finish()
    }
}

private enum OpenResult {
    case started
    case failed(String)
    case aborted
}

private enum CaptureOutcome {
    case ready(warning: String?)
    case failed(String)
    case aborted
}
