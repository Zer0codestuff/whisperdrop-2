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
    /// Most recent dictations, newest first, at most 20. Kept in memory only.
    @Published private(set) var recent: [String] = []
    /// True when dictation is enabled but the event tap was refused for lack of Input Monitoring.
    var requiredPermissionMissing: Bool { monitor.requiredPermissionMissing }

    private let settings: AppSettings
    private let host: ModelHost
    private let monitor: HotkeyMonitor
    private let mic: MicCapture
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
    private var cue: NSSound?

    private static let maxListenNanos: UInt64 = 600_000_000_000
    private static let failNanos: UInt64 = 2_500_000_000
    private static let recentLimit = 20

    init(settings: AppSettings, host: ModelHost) {
        self.settings = settings
        self.host = host
        self.monitor = HotkeyMonitor()
        self.mic = MicCapture()
        self.gesture = DictationGesture(
            mode: settings.dictationMode,
            doubleTapInterval: NSEvent.doubleClickInterval
        )
        let buffer = self.buffer
        let gate = self.levelGate
        mic.onSamples = { [buffer] samples in
            buffer.append(samples)
        }
        mic.onLevel = { [weak self, gate] level in
            guard gate.allow() else { return }
            Task { @MainActor in
                self?.noteLevel(level)
            }
        }
        monitor.onEvent = { [weak self] event in
            self?.handle(event)
        }
        monitor.onEscape = { [weak self] in
            self?.handleEscape()
        }
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
        failTask?.cancel()
        generation += 1
        let token = generation
        publish(.listening(handsFree: handsFree))
        host.prewarm(settings.model)
        // Hop so a slow device open does not stall the listen-only event tap.
        Task { [weak self] in
            guard let self else { return }
            if !MicCapture.isAuthorized {
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
        let model = settings.model
        let language = settings.spokenLanguage
        let vocabulary = settings.vocabulary.trimmingCharacters(in: .whitespacesAndNewlines)
        let prompt = vocabulary.isEmpty ? nil : vocabulary
        let paste = settings.autoPaste
        let restore = settings.restoreClipboard
        Task { [weak self] in
            guard let self else { return }
            let trimmed = SpeechDetector.trimSilence(captured)
            guard token == self.generation else { return }
            guard SpeechDetector.hasSpeech(trimmed) else {
                self.quietIdle(token)
                return
            }
            do {
                let transcription = try await self.host.transcribe(
                    trimmed,
                    model: model,
                    language: language,
                    prompt: prompt,
                    shortClip: true
                )
                guard token == self.generation else { return }
                guard let text = HallucinationFilter.dictationText(transcription, vocabulary: vocabulary) else {
                    self.quietIdle(token)
                    return
                }
                let pasted = await TextInserter.insert(text, paste: paste, restoreClipboard: restore)
                guard token == self.generation else { return }
                self.remember(text)
                self.play("Pop", volume: 0.18)
                if pasted {
                    self.publish(.idle)
                } else {
                    self.fail("Copied to clipboard")
                }
            } catch {
                guard token == self.generation else { return }
                self.fail(self.message(from: error, fallback: "Transcription failed."))
            }
        }
    }

    private func abandon() {
        stopTimers()
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
