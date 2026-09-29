import Foundation

/// Push-to-talk classification. Timestamps are monotonic seconds supplied by the caller.
/// Listening begins on the press. The hold threshold only chooses commit versus tap,
/// so the onset of speech is not dropped while the gesture waits to see a hold.
struct DictationGesture {
    enum Command: Equatable {
        case start(handsFree: Bool)
        case becomeHandsFree
        case commit
        case discard
    }

    var mode: DictationMode
    var holdThreshold: TimeInterval
    var doubleTapInterval: TimeInterval
    private(set) var pendingDiscardAt: TimeInterval?

    private enum Phase {
        case idle
        case pushDown(at: TimeInterval, secondTap: Bool)
        case awaitingSecondTap(deadline: TimeInterval)
        case handsFree
    }

    private var phase: Phase = .idle

    init(mode: DictationMode, holdThreshold: TimeInterval = 0.2, doubleTapInterval: TimeInterval = 0.5) {
        self.mode = mode
        self.holdThreshold = holdThreshold
        self.doubleTapInterval = doubleTapInterval
    }

    mutating func press(at time: TimeInterval) -> [Command] {
        switch phase {
        case .idle:
            return begin(at: time)
        case .awaitingSecondTap(let deadline):
            pendingDiscardAt = nil
            if time <= deadline {
                phase = .pushDown(at: time, secondTap: true)
                return []
            }
            phase = .pushDown(at: time, secondTap: false)
            return [.discard, .start(handsFree: false)]
        case .handsFree:
            phase = .idle
            pendingDiscardAt = nil
            return [.commit]
        case .pushDown:
            return []
        }
    }

    mutating func release(at time: TimeInterval) -> [Command] {
        switch phase {
        case .pushDown(let downAt, let secondTap):
            let elapsed = time - downAt
            if elapsed >= holdThreshold {
                phase = .idle
                pendingDiscardAt = nil
                return [.commit]
            }
            if secondTap {
                phase = .handsFree
                pendingDiscardAt = nil
                return [.becomeHandsFree]
            }
            if mode == .holdOrDoubleTap {
                let deadline = downAt + doubleTapInterval
                phase = .awaitingSecondTap(deadline: deadline)
                pendingDiscardAt = deadline
                return []
            }
            phase = .idle
            pendingDiscardAt = nil
            return [.discard]
        case .handsFree, .idle, .awaitingSecondTap:
            return []
        }
    }

    mutating func cancel(at time: TimeInterval) -> [Command] {
        _ = time
        switch phase {
        case .idle:
            return []
        case .pushDown, .awaitingSecondTap, .handsFree:
            phase = .idle
            pendingDiscardAt = nil
            return [.discard]
        }
    }

    /// Discards a short tap once `pendingDiscardAt` has passed without a second press.
    mutating func timeout(at time: TimeInterval) -> [Command] {
        guard case .awaitingSecondTap(let deadline) = phase, time >= deadline else { return [] }
        phase = .idle
        pendingDiscardAt = nil
        return [.discard]
    }

    mutating func reset() {
        phase = .idle
        pendingDiscardAt = nil
    }

    /// Menu-bar toggle starts a session that the next hotkey press ends.
    mutating func engageFromMenu() {
        phase = .handsFree
        pendingDiscardAt = nil
    }

    private mutating func begin(at time: TimeInterval) -> [Command] {
        pendingDiscardAt = nil
        switch mode {
        case .toggle:
            phase = .handsFree
            return [.start(handsFree: true)]
        case .hold, .holdOrDoubleTap:
            phase = .pushDown(at: time, secondTap: false)
            return [.start(handsFree: false)]
        }
    }
}
