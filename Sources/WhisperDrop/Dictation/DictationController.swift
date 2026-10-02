import AppKit
import Foundation
import WhisperDropCore

/// Contract file. Push-to-talk state machine: hotkey -> microphone -> ModelHost -> TextInserter, with the HUD.
@MainActor
final class DictationController: ObservableObject {
    enum State: Equatable { case idle, listening(handsFree: Bool), transcribing, failed(String) }
    @Published private(set) var state: State = .idle
    /// Smoothed microphone level, 0...1, for the HUD meter.
    @Published private(set) var level: Float = 0
    /// Words recognized so far while listening. Only fast engines provide them.
    @Published private(set) var preview = ""
    /// Live words for the dictation bar. Empty while the text field itself shows them.
    @Published private(set) var barText = ""
    /// Most recent dictations, newest first, at most 20. Kept in memory only.
    @Published private(set) var recent: [String] = []
    /// True when the model's files are installed.
    var modelInstalled: (TranscriptionModel) -> Bool = { _ in true }
    /// True when dictation is enabled but the event tap was refused for lack of Input Monitoring.
    var requiredPermissionMissing: Bool { monitor.requiredPermissionMissing }

    private let settings: AppSettings
    private let host: ModelHost
    private let monitor: HotkeyMonitor
    private var mic: any NoteCaptureSource
    private var replaying = false
    private let buffer = SampleBuffer()
    private let levelGate = LevelGate()
    private var gesture: DictationGesture
    private var hud: DictationHUD?
    private var generation = 0
    private var ignoreUntilUp = false
    private var draining = false
    private var queuedEvents: [HotkeyMonitor.Event] = []
    private var discardToken = 0
    private var discardTask: Task<Void, Never>?
    private var listenLimitTask: Task<Void, Never>?
    private var failTask: Task<Void, Never>?
    private var previewTask: Task<Void, Never>?
    private var live = LiveText()
    private var writer: LiveTextWriter?
    private var writerMode: LiveTextWriter.Mode?
    private var cue: NSSound?

    private static let maxListenNanos: UInt64 = 600_000_000_000
    private static let failNanos: UInt64 = 2_500_000_000
    private static let recentLimit = 20
    private static let previewInterval: Duration = .milliseconds(800)

    init(settings: AppSettings, host: ModelHost) {
        self.settings = settings
        self.host = host
        self.monitor = HotkeyMonitor()
        self.mic = MicCapture()
        self.gesture = DictationGesture(
            mode: settings.dictationMode,
            doubleTapInterval: NSEvent.doubleClickInterval
        )
        connect(mic)
        monitor.onEvent = { [weak self] event in
            self?.handle(event)
        }
        monitor.onEscape = { [weak self] in
            self?.handleEscape()
        }
    }

    private func connect(_ source: any NoteCaptureSource) {
        let buffer = self.buffer
        let gate = self.levelGate
        source.onSamples = { [buffer] samples in
            buffer.append(samples)
        }
        source.onLevel = { [weak self, gate] level in
            guard gate.allow() else { return }
            Task { @MainActor in
                self?.noteLevel(level)
            }
        }
    }

    /// Verification only: dictates `file` hands-free into the focused app, as if spoken, then finishes.
    func replay(_ file: URL) throws {
        let source = try DictationReplaySource(file: file)
        source.onEnd = { [weak self] in
            Task { @MainActor in
                guard let self, case .listening = self.state else { return }
                self.toggle()
            }
        }
        mic.stop()
        mic = source
        connect(source)
        replaying = true
        toggle()
    }

    /// Applies current settings (enabled, hotkey) and starts or stops the hotkey monitor.
    func refresh() {
        gesture.mode = settings.dictationMode
        gesture.doubleTapInterval = NSEvent.doubleClickInterval
        if !settings.dictationEnabled {
            if state != .idle {
                cancel()
            }
            monitor.stop()
            monitor.hotkey = settings.hotkey
            return
        }
        monitor.hotkey = settings.hotkey
        if !monitor.isRunning {
            monitor.start()
        }
    }

    /// Manual control, e.g. from the menu bar.
    func toggle() {
        switch state {
        case .transcribing:
            return
        case .listening:
            gesture.reset()
            finish()
        case .idle, .failed:
            gesture.engageFromMenu()
            begin(handsFree: true)
        }
    }

    /// Stops listening without transcribing.
    func cancel() {
        let showIdle: Bool
        switch state {
        case .idle: showIdle = false
        case .listening, .transcribing, .failed: showIdle = true
        }
        ignoreUntilUp = false
        failTask?.cancel()
        gesture.reset()
        stopTimers()
        dropWriter()
        mic.stop()
        _ = buffer.end()
        level = 0
        generation += 1
        if showIdle {
            publish(.idle)
        }
    }

    /// Copies the most recent dictation to the pasteboard.
    func copyLast() {
        guard let text = recent.first else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.prepareForNewContents(with: .currentHostOnly)
        pasteboard.setString(text, forType: .string)
    }

    private func handle(_ event: HotkeyMonitor.Event) {
        queuedEvents.append(event)
        guard !draining else { return }
        draining = true
        defer { draining = false }
        while !queuedEvents.isEmpty {
            let next = queuedEvents.removeFirst()
            handleNow(next)
        }
    }

    private func handleNow(_ event: HotkeyMonitor.Event) {
        if ignoreUntilUp || state == .transcribing {
            switch event {
            case .pressed:
                ignoreUntilUp = true
            case .released, .cancelled:
                ignoreUntilUp = false
            }
            return
        }
        let time = Self.now
        let commands: [DictationGesture.Command]
        switch event {
        case .pressed:
            commands = gesture.press(at: time)
        case .released:
            commands = gesture.release(at: time)
        case .cancelled:
            commands = gesture.cancel(at: time)
        }
        apply(commands)
    }

    private func handleEscape() {
        switch state {
        case .listening, .transcribing, .failed:
            cancel()
        case .idle:
            break
        }
    }

    private func apply(_ commands: [DictationGesture.Command]) {
        perform(commands)
        armDiscardTimer()
    }

    private func perform(_ commands: [DictationGesture.Command]) {
        for command in commands {
            switch command {
            case .start(let handsFree):
                begin(handsFree: handsFree)
            case .becomeHandsFree:
                if case .listening = state {
                    publish(.listening(handsFree: true))
                }
            case .commit:
                finish()
            case .discard:
                abandon()
            }
        }
    }

    private func begin(handsFree: Bool) {
        switch state {
        case .transcribing, .listening:
            return
        case .idle, .failed:
            break
        }
        let model = settings.model(for: .dictation)
        guard model.supports(language: settings.spokenLanguage) else {
            gesture.reset()
            fail("\(model.name) does not transcribe \(LiveFormat.language(settings.spokenLanguage)). Choose a Whisper model in Settings, Models.")
            return
        }
        guard modelInstalled(model) else {
            gesture.reset()
            fail("Download \(model.name) in Settings, Models first.")
            return
        }
        failTask?.cancel()
        generation += 1
        let token = generation
        publish(.listening(handsFree: handsFree))
        host.prewarm(model)
        // Hop so a slow device open does not stall the listen-only event tap.
        Task { [weak self] in
            guard let self else { return }
            if !self.replaying, !MicCapture.isAuthorized {
                let granted = await MicCapture.requestAccess()
                guard token == self.generation else { return }
                guard granted else {
                    self.gesture.reset()
                    self.fail("Allow microphone access to dictate.")
                    return
                }
            }
            self.openMicrophone(token: token)
        }
    }

    private func openMicrophone(token: Int) {
        guard token == generation, case .listening = state else { return }
        buffer.begin()
        do {
            try mic.start()
        } catch {
            _ = buffer.end()
            gesture.reset()
            fail(message(from: error, fallback: "The microphone could not be opened."))
            return
        }
        guard token == generation, case .listening = state else {
            mic.stop()
            _ = buffer.end()
            return
        }
        play("Tink", volume: 0.22)
        armListenLimit(token: token)
        startPreview(token: token)
    }

    /// Decodes the newest audio about every 0.8 seconds while listening, one request at a time. `LiveText` settles
    /// words once audio follows them, so each request stays short while the text covers everything said.
    /// With live text in the field, the writer puts the words into the focused app as they arrive.
    private func startPreview(token: Int) {
        previewTask?.cancel()
        preview = ""
        barText = ""
        live = LiveText()
        writerMode = nil
        let model = settings.model(for: .dictation)
        guard settings.dictationLiveText != .off, model.engine == .parakeet else { return }
        let language = settings.spokenLanguage
        let inField = settings.dictationLiveText == .inField && settings.autoPaste
        previewTask = Task { [weak self] in
            if inField {
                let frontmost = NSWorkspace.shared.frontmostApplication
                let attached = await Task.detached(priority: .userInitiated) { LiveTextWriter.attach(frontmost: frontmost) }.value
                guard let self, !Task.isCancelled, token == self.generation, case .listening = self.state else {
                    if let attached { Task { await attached.cancel() } }
                    return
                }
                self.writer = attached
            }
            var started = ContinuousClock.now
            while !Task.isCancelled {
                try? await Task.sleep(until: started + Self.previewInterval, clock: .continuous)
                started = ContinuousClock.now
                guard let self, !Task.isCancelled, token == self.generation, case .listening = self.state else { return }
                let available = Double(self.buffer.count) / Double(whisperSampleRate)
                guard let window = self.live.window(audioStart: 0, end: available) else { continue }
                let samples = self.buffer.slice(window)
                var words: [TranscriptWord] = []
                if SpeechDetector.hasSpeech(samples) {
                    guard let result = try? await self.host.transcribe(samples, model: model, language: language, offset: window.lowerBound, checkSilence: false),
                          !Task.isCancelled, token == self.generation, case .listening = self.state else { continue }
                    words = result.timedWords
                }
                self.live.accept(words, window: window)
                if let writer = self.writer {
                    self.writerMode = await writer.update(settled: self.live.settledText, text: self.live.text)
                    guard token == self.generation else { return }
                }
                self.publishLive()
            }
        }
    }

    private func publishLive() {
        preview = live.text
        switch writerMode {
        case .accessibility: barText = ""
        case .typing: barText = LiveText.join(live.pending)
        case .stopped, nil: barText = live.text
        }
    }

    /// Removes live text the writer put in the field, for Escape, a failure or a dictation without words.
    private func dropWriter() {
        guard let writer else { return }
        self.writer = nil
        writerMode = nil
        Task { await writer.cancel() }
    }

    private func finish() {
        guard case .listening = state else { return }
        stopTimers()
        generation += 1
        let token = generation
        mic.stop()
        let captured = buffer.end()
        level = 0
        publish(.transcribing)
        let model = settings.model(for: .dictation)
        let language = settings.spokenLanguage
        let vocabulary = settings.vocabulary.trimmingCharacters(in: .whitespacesAndNewlines)
        let prompt = vocabulary.isEmpty ? nil : vocabulary
        let paste = settings.autoPaste
        let restore = settings.restoreClipboard
        let live = self.live
        let writer = self.writer
        // Typed words cannot be corrected without deleting them again, so they stay and only the rest is decoded.
        // Everywhere else the whole clip is decoded again, which is more accurate, and the field is corrected in place.
        let keepSettled = writerMode == .typing && !live.settled.isEmpty
        self.writer = nil
        writerMode = nil
        Task { [weak self] in
            guard let self else { return }
            do {
                let text: String?
                if keepSettled {
                    text = try await self.finishLive(live, captured: captured, model: model, language: language)
                } else {
                    let trimmed = SpeechDetector.trimSilence(captured)
                    if SpeechDetector.hasSpeech(trimmed) {
                        let transcription = try await self.host.transcribe(trimmed, model: model, language: language, prompt: prompt, shortClip: true)
                        text = HallucinationFilter.dictationText(transcription, vocabulary: vocabulary)
                    } else {
                        text = nil
                    }
                }
                guard token == self.generation else { await writer?.cancel(); return }
                guard let text else {
                    await writer?.cancel()
                    self.quietIdle(token)
                    return
                }
                switch await writer?.finish(text) {
                case .written?:
                    guard token == self.generation else { return }
                    self.remember(text)
                    self.play("Pop", volume: 0.18)
                    self.publish(.idle)
                case .partial?:
                    guard token == self.generation else { return }
                    self.remember(text)
                    self.copyLast()
                    self.fail("The text field changed. The full text is copied")
                case .untouched?, nil:
                    let lead = paste ? await Task.detached(priority: .userInitiated) { LiveTextWriter.leadingSpaceAtCaret() }.value : ""
                    let pasted = await TextInserter.insert(lead + text, paste: paste, restoreClipboard: restore)
                    guard token == self.generation else { return }
                    self.remember(text)
                    self.play("Pop", volume: 0.18)
                    if pasted {
                        self.publish(.idle)
                    } else {
                        self.fail("Copied to clipboard")
                    }
                }
            } catch {
                await writer?.cancel()
                guard token == self.generation else { return }
                self.fail(self.message(from: error, fallback: "Transcription failed."))
            }
        }
    }

    /// Decodes the audio after the settled words, with a little context before them, and joins the result.
    private func finishLive(_ live: LiveText, captured: [Float], model: TranscriptionModel, language: String) async throws -> String? {
        var live = live
        let end = Double(captured.count) / Double(whisperSampleRate)
        let window = max(0, live.settledUntil - live.leftContext)..<max(end, live.settledUntil)
        let tail = Self.slice(captured, window)
        if SpeechDetector.hasSpeech(tail) {
            let result = try await host.transcribe(tail, model: model, language: language, offset: window.lowerBound, shortClip: true)
            live.accept(result.timedWords, window: window, final: true)
        } else {
            live.accept([], window: window, final: true)
        }
        let joined = TranscriptSegment(id: 0, start: 0, end: end, text: live.settledText, words: live.settled)
        return HallucinationFilter.dictationText(ServerTranscription(segments: [joined], language: nil), vocabulary: "")
    }

    nonisolated static func slice(_ samples: [Float], _ window: Range<Double>) -> [Float] {
        let from = max(0, min(samples.count, Int((window.lowerBound * Double(whisperSampleRate)).rounded())))
        let to = max(from, min(samples.count, Int((window.upperBound * Double(whisperSampleRate)).rounded())))
        return Array(samples[from..<to])
    }

    private func abandon() {
        stopTimers()
        dropWriter()
        failTask?.cancel()
        generation += 1
        mic.stop()
        _ = buffer.end()
        level = 0
        if state != .idle {
            publish(.idle)
        }
    }

    private func quietIdle(_ token: Int) {
        guard token == generation, case .transcribing = state else { return }
        publish(.idle)
    }

    private func fail(_ message: String) {
        stopTimers()
        dropWriter()
        mic.stop()
        _ = buffer.end()
        level = 0
        generation += 1
        let token = generation
        publish(.failed(message))
        failTask?.cancel()
        failTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: Self.failNanos)
            guard let self, !Task.isCancelled, token == self.generation else { return }
            if case .failed = self.state {
                self.publish(.idle)
            }
        }
    }

    private func remember(_ text: String) {
        recent.insert(text, at: 0)
        if recent.count > Self.recentLimit {
            recent.removeLast(recent.count - Self.recentLimit)
        }
    }

    private func armListenLimit(token: Int) {
        listenLimitTask?.cancel()
        listenLimitTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: Self.maxListenNanos)
            guard let self, !Task.isCancelled, token == self.generation else { return }
            guard case .listening = self.state else { return }
            self.gesture.reset()
            self.finish()
        }
    }

    private func armDiscardTimer() {
        discardToken += 1
        let token = discardToken
        guard let deadline = gesture.pendingDiscardAt else { return }
        discardTask = Task { [weak self] in
            guard let self else { return }
            var spins = 0
            while token == self.discardToken, spins < 3 {
                let remaining = deadline - Self.now
                if remaining <= 0.005 { break }
                try? await Task.sleep(nanoseconds: UInt64((remaining * 1_000_000_000).rounded()))
                guard !Task.isCancelled else { return }
                spins += 1
            }
            guard token == self.discardToken else { return }
            let commands = self.gesture.timeout(at: max(Self.now, deadline))
            guard token == self.discardToken else { return }
            self.perform(commands)
        }
    }

    private func stopTimers() {
        previewTask?.cancel()
        previewTask = nil
        preview = ""
        barText = ""
        discardToken += 1
        discardTask?.cancel()
        discardTask = nil
        listenLimitTask?.cancel()
        listenLimitTask = nil
    }

    private func noteLevel(_ raw: Float) {
        guard case .listening = state else { return }
        let clamped = min(max(raw, 0), 1)
        level = level * 0.55 + clamped * 0.45
    }

    private func play(_ name: String, volume: Float) {
        guard settings.sounds else { return }
        guard let sound = NSSound(named: NSSound.Name(name)) else { return }
        sound.volume = volume
        sound.play()
        cue = sound
    }

    private func publish(_ newState: State) {
        state = newState
        if hud == nil {
            hud = DictationHUD(controller: self)
        }
        hud?.update()
    }

    private func message(from error: Error, fallback: String) -> String {
        let text = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? fallback : text
    }

    private static var now: TimeInterval { ProcessInfo.processInfo.systemUptime }
}

/// Lock-protected capture buffer. `append` runs on the audio thread.
private final class SampleBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var samples: [Float] = []
    private var accepting = false
    private let cap = 16_000 * 600

    func begin() {
        lock.lock()
        samples.removeAll(keepingCapacity: true)
        accepting = true
        lock.unlock()
    }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return samples.count
    }

    /// Copy of the samples inside `window` seconds, while capture continues.
    func slice(_ window: Range<Double>) -> [Float] {
        lock.lock()
        defer { lock.unlock() }
        return DictationController.slice(samples, window)
    }

    func end() -> [Float] {
        lock.lock()
        accepting = false
        let taken = samples
        samples.removeAll(keepingCapacity: false)
        lock.unlock()
        return taken
    }

    func append(_ chunk: [Float]) {
        lock.lock()
        defer { lock.unlock() }
        guard accepting, samples.count < cap, !chunk.isEmpty else { return }
        let room = cap - samples.count
        if chunk.count <= room {
            samples.append(contentsOf: chunk)
        } else {
            samples.append(contentsOf: chunk.prefix(room))
        }
    }
}

/// Drops level callbacks faster than about 20 Hz before they hop to the main actor.
private final class LevelGate: @unchecked Sendable {
    private let lock = NSLock()
    private var last = 0.0

    func allow(interval: TimeInterval = 0.05) -> Bool {
        let now = ProcessInfo.processInfo.systemUptime
        lock.lock()
        defer { lock.unlock() }
        guard now - last >= interval else { return false }
        last = now
        return true
    }
}
