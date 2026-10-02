import AppKit
import ApplicationServices
import Carbon
import Foundation
import WhisperDropCore

/// Writes dictation live text into the text field that had focus when dictation started.
///
/// Native text views accept Accessibility edits, so live words are written and corrected in place. Web content in
/// Safari and Chrome reports those edits as successful without changing anything, so every edit is read back.
/// When a field ignores it, the writer types settled words instead and only ever deletes characters it typed itself.
/// If the user moves the caret, types or changes focus, the writer stops touching the field; `finish` then reports
/// that the field holds only part of the text so the caller can copy the full text instead.
final class LiveTextWriter: @unchecked Sendable {
    enum Mode: Equatable { case accessibility, typing, stopped }
    enum Outcome: Equatable {
        /// The field holds the final text.
        case written
        /// Nothing was written. Insert the text the usual way.
        case untouched
        /// The field changed under the writer and holds only part of the text.
        case partial
    }

    /// Marks key events this writer posts, so the dictation hotkey monitor does not treat them as a shortcut chord.
    static let eventMarker: Int64 = 0x5744_4C54
    /// Set WHISPERDROP_LIVE_TEXT_LOG=1 to trace decisions on standard error.
    private static let tracing = ProcessInfo.processInfo.environment["WHISPERDROP_LIVE_TEXT_LOG"] == "1"
    private static func trace(_ message: @autoclosure () -> String) {
        if tracing { FileHandle.standardError.write(Data(("live text: " + message() + "\n").utf8)) }
    }

    private let queue = DispatchQueue(label: "whisperdrop.live-text", qos: .userInitiated)
    private let element: AXUIElement
    private let application: AXUIElement?
    private let restoreEnhancedInterface: Bool
    private var mode: Mode
    /// UTF-16 location where dictated text begins, and the selection it replaces first.
    private var origin: Int
    private var replacedLength: Int
    /// Text this writer has put in the field.
    private var written = ""
    private var readable: Bool
    /// A space when the caret follows other text, so dictation does not join the previous word.
    private let lead: String

    private init(element: AXUIElement, application: AXUIElement?, restoreEnhancedInterface: Bool, mode: Mode,
                 origin: Int, replacedLength: Int, readable: Bool, lead: String) {
        self.element = element; self.application = application; self.restoreEnhancedInterface = restoreEnhancedInterface
        self.mode = mode; self.origin = origin; self.replacedLength = replacedLength; self.readable = readable; self.lead = lead
    }

    /// The focused text field, or nil when nothing editable has focus or secure input is on.
    /// `frontmost` is read on the main thread by the caller; this method makes blocking Accessibility calls.
    static func attach(frontmost: NSRunningApplication?) -> LiveTextWriter? {
        guard AXIsProcessTrusted(), !IsSecureEventInputEnabled(), CGPreflightPostEventAccess() else { return nil }
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 0.4)
        var target = Self.focused(in: system)
        var application: AXUIElement?
        var enhanced = false
        if target.map(Self.isText) != true, let app = frontmost,
           app.processIdentifier != ProcessInfo.processInfo.processIdentifier {
            // Electron apps build their accessibility tree on request; Chromium browsers need the enhanced interface flag.
            let element = AXUIElementCreateApplication(app.processIdentifier)
            AXUIElementSetMessagingTimeout(element, 0.4)
            application = element
            AXUIElementSetAttributeValue(element, "AXManualAccessibility" as CFString, kCFBooleanTrue)
            target = Self.focused(in: element)
            if target.map(Self.isText) != true, Self.isChromium(app) {
                // Chrome reports an error for this flag but builds its tree anyway, about two seconds later the first time.
                AXUIElementSetAttributeValue(element, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
                enhanced = true
                for _ in 0..<30 where target.map(Self.isText) != true {
                    Thread.sleep(forTimeInterval: 0.1)
                    target = Self.focused(in: element)
                }
            }
        }
        trace("focused role \(target.map(Self.role) ?? "none"), app \(frontmost?.bundleIdentifier ?? "none"), enhanced \(enhanced)")
        guard let element = target, Self.isText(element) else {
            if enhanced, let application { AXUIElementSetAttributeValue(application, "AXEnhancedUserInterface" as CFString, kCFBooleanFalse) }
            return nil
        }
        AXUIElementSetMessagingTimeout(element, 0.4)
        let range = Self.selectedRange(element)
        let settable = Self.settable(element, kAXSelectedTextAttribute) && Self.settable(element, kAXSelectedTextRangeAttribute)
        trace("attached, settable \(settable), range \(range.map { "\($0.location),\($0.length)" } ?? "none")")
        return LiveTextWriter(element: element, application: application, restoreEnhancedInterface: enhanced,
                              mode: settable && range != nil ? .accessibility : .typing,
                              origin: range?.location ?? 0, replacedLength: range?.length ?? 0,
                              readable: range != nil && Self.text(element, at: CFRange(location: 0, length: 0)) != nil,
                              lead: Self.leadingSpace(element, before: range))
    }

    /// A space when the focused field's caret follows text, for the usual paste path. Empty when unknown.
    static func leadingSpaceAtCaret() -> String {
        guard AXIsProcessTrusted() else { return "" }
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 0.3)
        guard let element = focused(in: system) else { return "" }
        AXUIElementSetMessagingTimeout(element, 0.3)
        return leadingSpace(element, before: selectedRange(element))
    }

    private static func leadingSpace(_ element: AXUIElement, before range: CFRange?) -> String {
        guard let range, range.location > 0,
              let previous = text(element, at: CFRange(location: range.location - 1, length: 1))?.first else { return "" }
        return previous.isWhitespace || "([{\"'«“‘/".contains(previous) ? "" : " "
    }

    /// Shows `text` in the field. Accessibility mode writes all of it; typing mode types only the `settled` part.
    /// Returns the mode afterwards: with `.typing` the unsettled words are not in the field yet.
    @discardableResult
    func update(settled: String, text: String) async -> Mode {
        await run {
            switch self.mode {
            case .accessibility:
                if !self.replace(with: self.shape(text)) { self.type(toward: self.shape(settled)) }
            case .typing: self.type(toward: self.shape(settled))
            case .stopped: break
            }
            return self.mode
        }
    }

    /// Writes the final text where dictation began.
    func finish(_ text: String) async -> Outcome {
        let final = shape(text)
        return await run {
            defer { self.release() }
            switch self.mode {
            case .accessibility:
                if !self.replace(with: final) { self.type(toward: final, correcting: true) }
            case .typing: self.type(toward: final, correcting: true)
            case .stopped: break
            }
            // Nothing of ours is in the field, so the usual paste can still insert the text.
            if self.written.isEmpty { return final.isEmpty ? .written : .untouched }
            return self.mode != .stopped && self.written == final ? .written : .partial
        }
    }

    /// Removes the live text, for Escape or a dictation without speech.
    func cancel() async {
        _ = await finish("")
    }

    // MARK: Editing

    /// Edits the field in place. Returns false when the writer switched to typing because the field ignored the edit.
    private func replace(with text: String) -> Bool {
        guard text != written else { return true }
        guard stillOwnsCaret() else { Self.trace("caret moved before edit"); stop(); return true }
        let edit = LiveTextEdit.between(written, text)
        guard case .replace(let deleteCount, let insert) = edit else { return true }
        let kept = String(written.prefix(written.count - deleteCount))
        let firstWrite = written.isEmpty
        let start = origin + kept.utf16.count
        let length = firstWrite ? replacedLength : written.utf16.count - kept.utf16.count
        if Self.select(element, CFRange(location: start, length: length)),
           AXUIElementSetAttributeValue(element, kAXSelectedTextAttribute as CFString, insert as CFString) == .success,
           Self.text(element, at: CFRange(location: origin, length: text.utf16.count)) == text {
            written = text
            replacedLength = 0
            return true
        }
        // Web content accepts the call and keeps its text. Type instead, but only if the field is untouched.
        if firstWrite, let range = Self.selectedRange(element), range.location == origin {
            Self.trace("edit ignored, typing instead")
            mode = .typing
            return false
        }
        Self.trace("edit failed, stopping")
        stop()
        return true
    }

    /// Types the part of `target` after what was typed. Deletes typed characters only when `correcting` and the
    /// field still shows them before the caret.
    private func type(toward target: String, correcting: Bool = false) {
        guard target != written else { return }
        guard stillOwnsCaret() else { Self.trace("caret moved before typing"); return stop() }
        let edit = LiveTextEdit.between(written, target)
        guard case .replace(let deleteCount, let insert) = edit else { return }
        if deleteCount > 0 {
            guard correcting else { return }
            Self.postBackspaces(deleteCount)
            written = String(written.prefix(written.count - deleteCount))
        }
        if !insert.isEmpty {
            Self.postText(insert)
            written += insert
        }
        if readable {
            // Give the app a moment to apply the events before checking.
            Thread.sleep(forTimeInterval: 0.05)
            if !stillOwnsCaret(settleTime: 0.25) { Self.trace("typed text not found after typing"); stop() }
        }
    }

    /// The field still has focus and the caret sits right after the written text, unchanged by the user.
    private func stillOwnsCaret(settleTime: Double = 0) -> Bool {
        guard mode != .stopped else { return false }
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 0.4)
        if let focused = Self.focused(in: system) ?? application.flatMap(Self.focused(in:)), !CFEqual(focused, element) { return false }
        guard readable else { return true }
        let deadline = Date().addingTimeInterval(settleTime)
        repeat {
            if let range = Self.selectedRange(element) {
                let expectedLocation = origin + written.utf16.count
                let selectionOK = written.isEmpty ? range.location == origin : (range.location == expectedLocation && range.length == 0)
                if selectionOK, written.isEmpty || Self.text(element, at: CFRange(location: origin, length: written.utf16.count)) == written {
                    return true
                }
            } else {
                return true
            }
            if Date() >= deadline { return false }
            Thread.sleep(forTimeInterval: 0.05)
        } while true
    }

    private func stop() { mode = .stopped }

    private func release() {
        if restoreEnhancedInterface, let application {
            AXUIElementSetAttributeValue(application, "AXEnhancedUserInterface" as CFString, kCFBooleanFalse)
        }
    }

    private func run<T>(_ work: @escaping () -> T) async -> T {
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume(returning: work()) }
        }
    }

    // MARK: Accessibility

    private static func focused(in element: AXUIElement) -> AXUIElement? {
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(element, kAXFocusedUIElementAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    private static func role(_ element: AXUIElement) -> String {
        var value: AnyObject?
        AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &value)
        return value as? String ?? "unknown"
    }

    private static func isText(_ element: AXUIElement) -> Bool {
        var value: AnyObject?
        AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &value)
        let role = value as? String ?? ""
        if ["AXTextField", "AXTextArea", "AXComboBox", "AXSearchField"].contains(role) { return true }
        return selectedRange(element) != nil && settable(element, kAXValueAttribute)
    }

    private static func settable(_ element: AXUIElement, _ attribute: String) -> Bool {
        var result: DarwinBoolean = false
        return AXUIElementIsAttributeSettable(element, attribute as CFString, &result) == .success && result.boolValue
    }

    private static func selectedRange(_ element: AXUIElement) -> CFRange? {
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var range = CFRange()
        return AXValueGetValue(value as! AXValue, .cfRange, &range) ? range : nil
    }

    private static func select(_ element: AXUIElement, _ range: CFRange) -> Bool {
        var range = range
        guard let value = AXValueCreate(.cfRange, &range) else { return false }
        return AXUIElementSetAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, value) == .success
    }

    /// Text in `range`, from the range attribute when the app provides it, else from the whole value.
    private static func text(_ element: AXUIElement, at range: CFRange) -> String? {
        var parameter = range
        if let value = AXValueCreate(.cfRange, &parameter) {
            var result: AnyObject?
            if AXUIElementCopyParameterizedAttributeValue(element, kAXStringForRangeParameterizedAttribute as CFString, value, &result) == .success,
               let string = result as? String {
                return string
            }
        }
        var whole: AnyObject?
        guard AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &whole) == .success, let string = whole as? String else { return nil }
        let ns = string as NSString
        guard range.location >= 0, range.location + range.length <= ns.length else { return nil }
        return ns.substring(with: NSRange(location: range.location, length: range.length))
    }

    private static func isChromium(_ app: NSRunningApplication) -> Bool {
        let id = app.bundleIdentifier ?? ""
        return ["com.google.Chrome", "com.google.Chrome.beta", "com.google.Chrome.canary", "com.microsoft.edgemac",
                "com.brave.Browser", "company.thebrowser.Browser", "com.vivaldi.Vivaldi", "com.operasoftware.Opera"].contains(id)
    }

    // MARK: Keyboard

    /// Dictated text is one line. A typed newline could send a chat message.
    private func shape(_ text: String) -> String {
        let line = text.split(whereSeparator: \.isNewline).joined(separator: " ")
        return line.isEmpty ? "" : lead + line
    }

    private static func postText(_ text: String) {
        let source = CGEventSource(stateID: .privateState)
        var piece: [UInt16] = []
        func send() {
            guard !piece.isEmpty else { return }
            for down in [true, false] {
                guard let event = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: down) else { continue }
                event.flags = []
                event.keyboardSetUnicodeString(stringLength: piece.count, unicodeString: piece)
                event.setIntegerValueField(.eventSourceUserData, value: eventMarker)
                event.post(tap: .cghidEventTap)
            }
            piece.removeAll()
            Thread.sleep(forTimeInterval: 0.006)
        }
        for character in text {
            let units = Array(String(character).utf16)
            if piece.count + units.count > 16 { send() }
            piece += units
        }
        send()
    }

    private static func postBackspaces(_ count: Int) {
        let source = CGEventSource(stateID: .privateState)
        for _ in 0..<count {
            for down in [true, false] {
                guard let event = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_Delete), keyDown: down) else { continue }
                event.flags = []
                event.setIntegerValueField(.eventSourceUserData, value: eventMarker)
                event.post(tap: .cghidEventTap)
            }
            Thread.sleep(forTimeInterval: 0.004)
        }
    }
}
