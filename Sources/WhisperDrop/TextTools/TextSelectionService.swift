import AppKit
import ApplicationServices
import Carbon

/// Text captured from another app. The source remains private so callers cannot invent a replacement target.
struct TextSelectionSnapshot {
    let text: String
    /// Accessibility screen coordinates, whose origin is at the top left of the main display.
    let rect: NSRect?
    let canReplace: Bool
    var sourceAppName: String? { source.app.localizedName }
    fileprivate let source: TextSelectionSource
}

/// The field and its contents before dictation. It is useful only after the inserted text is read back.
struct TextInsertionTarget {
    fileprivate let app: NSRunningApplication
    fileprivate let element: AXUIElement
    fileprivate let range: CFRange
    fileprivate let wholeValue: String
}

fileprivate struct TextSelectionSource {
    enum Method { case accessibility, clipboard, insertion }
    let app: NSRunningApplication
    let element: AXUIElement?
    let range: CFRange?
    let wholeValue: String?
    let caret: CFRange?
    let method: Method
}

private enum TextSelectionError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let text) = self { return text }; return nil }
}

/// A narrow Accessibility and pasteboard bridge. Every replacement revalidates the captured source.
@MainActor
final class TextSelectionService {
    private var lastExternalApp: NSRunningApplication?
    private var activationObserver: NSObjectProtocol?
    private var operationInProgress = false
    private let ownPID = ProcessInfo.processInfo.processIdentifier
    private static let transientType = NSPasteboard.PasteboardType("org.nspasteboard.TransientType")

    init() {
        if let frontmost = NSWorkspace.shared.frontmostApplication, frontmost.processIdentifier != ownPID {
            lastExternalApp = frontmost
        }
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] notification in
            guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return }
            MainActor.assumeIsolated { self?.lastExternalApp = app }
        }
    }

    deinit {
        if let activationObserver { NSWorkspace.shared.notificationCenter.removeObserver(activationObserver) }
    }

    var trusted: Bool { AXIsProcessTrusted() }

    func requestAccess() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    /// Clipboard fallback never activates a background app and always restores the previous clipboard.
    func capture() async throws -> TextSelectionSnapshot {
        guard !operationInProgress else { throw issue("A text action is already in progress.") }
        operationInProgress = true
        defer { operationInProgress = false }
        guard trusted else { throw issue("Allow Accessibility in Settings to read selected text. You can also paste text into Writing.") }
        let frontmost = NSWorkspace.shared.frontmostApplication
        let externalIsFrontmost = frontmost.map { $0.processIdentifier != ownPID } ?? false
        guard let app = externalIsFrontmost ? frontmost : lastExternalApp, !app.isTerminated, app.processIdentifier != ownPID else {
            throw issue("Select text in another app, then press the text shortcut.")
        }
        let application = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(application, 0.3)
        _ = AXUIElementSetAttributeValue(application, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        let element = focused(app)
        guard !isSecure(element), !IsSecureEventInputEnabled() else { throw issue("WhisperDrop does not read password fields.") }
        if let element, let text = attribute(element, kAXSelectedTextAttribute) as? String,
           !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let range = selectedRange(element)
            let wholeValue = attribute(element, kAXValueAttribute) as? String
            let source = TextSelectionSource(app: app, element: element, range: range, wholeValue: wholeValue, caret: nil, method: .accessibility)
            return TextSelectionSnapshot(text: text, rect: range.flatMap { bounds(of: $0, in: element) },
                                         canReplace: isEditable(element), source: source)
        }
        guard externalIsFrontmost else { throw issue("This app did not share a text selection. Copy the text and paste it into Writing.") }
        guard let text = try await copySelection(from: app, expectedElement: element),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw issue("No selected text was found. Select text and try again.")
        }
        let range = element.flatMap(selectedRange)
        let source = TextSelectionSource(app: app, element: element, range: range,
                                        wholeValue: element.flatMap { attribute($0, kAXValueAttribute) as? String }, caret: nil, method: .clipboard)
        return TextSelectionSnapshot(text: text, rect: element.flatMap { element in range.flatMap { bounds(of: $0, in: element) } },
                                     canReplace: element.map(isEditable) ?? false, source: source)
    }

    /// Captures a baseline without changing focus, selection or clipboard.
    func captureInsertionTarget() -> TextInsertionTarget? {
        guard trusted, !IsSecureEventInputEnabled(), let app = NSWorkspace.shared.frontmostApplication,
              app.processIdentifier != ownPID else { return nil }
        _ = AXUIElementSetAttributeValue(AXUIElementCreateApplication(app.processIdentifier), "AXManualAccessibility" as CFString, kCFBooleanTrue)
        guard let element = focused(app), !isSecure(element), isEditable(element),
              let range = selectedRange(element), let whole = attribute(element, kAXValueAttribute) as? String,
              valid(range, in: whole) else { return nil }
        return TextInsertionTarget(app: app, element: element, range: range, wholeValue: whole)
    }

    /// Proves that only the dictated words were inserted into the baseline field. No range is selected here.
    /// Unreadable fields, a changed focus, edited surrounding text, or a moved caret produce a copy-only result.
    func snapshotInsertedText(_ text: String, target: TextInsertionTarget?) async -> TextSelectionSnapshot? {
        guard let target, !text.isEmpty else { return nil }
        let line = text.split(whereSeparator: \.isNewline).joined(separator: " ")
        guard !line.isEmpty else { return nil }
        for attempt in 0..<8 {
            if let snapshot = insertedSnapshot(line, target: target) { return snapshot }
            if attempt < 7 { try? await Task.sleep(for: .milliseconds(75)) }
        }
        return nil
    }

    /// Returns true only after the source app reports the expected result. An unconfirmed paste returns false.
    @discardableResult
    func replace(_ snapshot: TextSelectionSnapshot, with text: String) async throws -> Bool {
        guard !operationInProgress else { throw issue("A text action is already in progress.") }
        operationInProgress = true
        defer { operationInProgress = false }
        guard snapshot.canReplace else { throw issue("This source does not support safe replacement. Copy the result instead.") }
        guard trusted, !snapshot.source.app.isTerminated, !IsSecureEventInputEnabled() else {
            throw issue("The source app is unavailable. Copy the result instead.")
        }
        let source = snapshot.source
        try await returnToSource(source.app)
        guard await waitForModifierRelease() else { throw issue("Release the shortcut keys and try again.") }
        try Task.checkCancellation()
        try validate(snapshot)
        if source.method == .clipboard {
            guard try await copySelection(from: source.app, expectedElement: source.element) == snapshot.text else {
                throw issue("The original selection changed. Select it again or copy the result.")
            }
            try Task.checkCancellation()
            try validate(snapshot)
        }
        if text == snapshot.text { return true }
        if source.method == .insertion {
            // Select only the range whose complete text and surrounding field were just verified.
            guard let element = source.element, let range = source.range, select(element, range),
                  same(selectedRange(element), range), attribute(element, kAXSelectedTextAttribute) as? String == snapshot.text else {
                throw issue("The dictated words could not be selected safely. Copy the result instead.")
            }
        }
        guard isFrontmost(source.app), sameFocus(as: source), !IsSecureEventInputEnabled() else {
            throw issue("The source field changed. Copy the result instead.")
        }
        try Task.checkCancellation()
        let pasteboard = NSPasteboard.general
        guard clipboardAvailable(pasteboard), let saved = clipboardSnapshot(pasteboard) else {
            throw issue("The clipboard cannot be preserved. Copy the result instead.")
        }
        pasteboard.clearContents()
        guard pasteboard.setString(text, forType: .string) else {
            restore(saved, to: pasteboard)
            throw issue("Could not copy the result for replacement.")
        }
        pasteboard.setData(Data(), forType: Self.transientType)
        let changeCount = pasteboard.changeCount
        guard postCommand(CGKeyCode(kVK_ANSI_V)) else {
            if pasteboard.changeCount == changeCount { restore(saved, to: pasteboard) }
            throw issue("Could not paste the result. Use Copy instead.")
        }
        var confirmed = false
        for _ in 0..<8 {
            await settlePostedEvent(for: .milliseconds(75))
            if pasteApplied(snapshot, text: text) { confirmed = true; break }
        }
        // Even an editor that cannot expose read-back needs time to consume the pasteboard.
        if !confirmed { await settlePostedEvent(for: .milliseconds(150)) }
        if pasteboard.changeCount == changeCount { restore(saved, to: pasteboard) }
        try Task.checkCancellation()
        return confirmed
    }

    private func insertedSnapshot(_ text: String, target: TextInsertionTarget) -> TextSelectionSnapshot? {
        guard isFrontmost(target.app), let element = focused(target.app), CFEqual(element, target.element),
              let now = attribute(element, kAXValueAttribute) as? String, let caret = selectedRange(element), caret.length == 0 else { return nil }
        for lead in ["", " "] {
            let inserted = lead + text
            guard replacing(target.wholeValue, range: target.range, with: inserted) == now,
                  caret.location == target.range.location + inserted.utf16.count else { continue }
            let range = CFRange(location: target.range.location + lead.utf16.count, length: text.utf16.count)
            let source = TextSelectionSource(app: target.app, element: element, range: range, wholeValue: now, caret: caret, method: .insertion)
            return TextSelectionSnapshot(text: text, rect: bounds(of: range, in: element), canReplace: true, source: source)
        }
        return nil
    }

    private func validate(_ snapshot: TextSelectionSnapshot) throws {
        let source = snapshot.source
        guard isFrontmost(source.app), let current = focused(source.app), sameFocus(as: source), !isSecure(current) else {
            throw issue("The source field changed. Select the text again or copy the result.")
        }
        let valueNow = attribute(current, kAXValueAttribute) as? String
        if let previous = source.wholeValue, valueNow != previous {
            throw issue("The source text changed while WhisperDrop was working. Copy the result or start again.")
        }
        if source.method == .insertion {
            guard let range = source.range, let whole = valueNow, substring(whole, range: range) == snapshot.text,
                  let caret = source.caret, same(selectedRange(current), caret) else {
                throw issue("The caret or dictated words changed. Copy the result instead.")
            }
        } else {
            if let range = source.range, !same(selectedRange(current), range) {
                throw issue("The selection moved. Select it again before replacing.")
            }
            if source.method == .accessibility, attribute(current, kAXSelectedTextAttribute) as? String != snapshot.text {
                throw issue("The original selection changed. Select it again or copy the result.")
            }
        }
    }

    private func pasteApplied(_ snapshot: TextSelectionSnapshot, text: String) -> Bool {
        let source = snapshot.source
        guard isFrontmost(source.app), sameFocus(as: source), let element = focused(source.app),
              let before = source.wholeValue, let range = source.range,
              let now = attribute(element, kAXValueAttribute) as? String,
              replacing(before, range: range, with: text) == now else { return false }
        return true
    }

    private func returnToSource(_ app: NSRunningApplication) async throws {
        if !isFrontmost(app) {
            NSApp.yieldActivation(to: app)
            app.activate()
            for _ in 0..<40 {
                if isFrontmost(app) { break }
                try await Task.sleep(for: .milliseconds(25))
            }
        }
        guard isFrontmost(app) else { throw issue("Could not return to \(app.localizedName ?? "the source app"). Copy the result instead.") }
        try await Task.sleep(for: .milliseconds(120))
    }

    private func copySelection(from app: NSRunningApplication, expectedElement: AXUIElement?) async throws -> String? {
        guard await waitForModifierRelease() else { throw issue("Release the shortcut keys and try again.") }
        try Task.checkCancellation()
        try await Task.sleep(for: .milliseconds(60))
        guard isFrontmost(app), matchesFocus(expectedElement, in: app), !IsSecureEventInputEnabled() else { return nil }
        let pasteboard = NSPasteboard.general
        guard clipboardAvailable(pasteboard), let saved = clipboardSnapshot(pasteboard) else {
            throw issue("The clipboard cannot be preserved. Copy the text and paste it into Writing.")
        }
        let before = pasteboard.changeCount
        guard postCommand(CGKeyCode(kVK_ANSI_C)) else { throw issue("Could not read the selection. Copy the text and paste it into Writing.") }
        var copied: String?
        var copiedChangeCount: Int?
        for _ in 0..<24 {
            await settlePostedEvent(for: .milliseconds(25))
            if pasteboard.changeCount != before {
                await settlePostedEvent(for: .milliseconds(40))
                copiedChangeCount = pasteboard.changeCount
                copied = pasteboard.string(forType: .string)
                break
            }
        }
        if let copiedChangeCount, pasteboard.changeCount == copiedChangeCount { restore(saved, to: pasteboard) }
        try Task.checkCancellation()
        guard isFrontmost(app), matchesFocus(expectedElement, in: app) else { return nil }
        return copied
    }

    /// Once an event is posted, finish the clipboard transaction even if its caller cancels.
    /// A canceled Task.sleep returns immediately, which could restore before the editor consumes a paste,
    /// or miss a delayed copy and leave its contents on the user's clipboard after cancellation.
    private func settlePostedEvent(for duration: Duration) async {
        await Task.detached { try? await Task.sleep(for: duration) }.value
    }

    private func waitForModifierRelease() async -> Bool {
        let modifiers: CGEventFlags = [.maskControl, .maskAlternate, .maskShift, .maskCommand]
        for _ in 0..<40 {
            if CGEventSource.flagsState(.combinedSessionState).intersection(modifiers).isEmpty { return true }
            try? await Task.sleep(for: .milliseconds(25))
        }
        return false
    }

    private func postCommand(_ key: CGKeyCode) -> Bool {
        guard CGPreflightPostEventAccess(), let source = CGEventSource(stateID: .privateState),
              let down = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: false) else { return false }
        for event in [down, up] {
            event.flags = .maskCommand
            event.setIntegerValueField(.eventSourceUserData, value: LiveTextWriter.eventMarker)
            event.post(tap: .cghidEventTap)
        }
        return true
    }

    private func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        AXUIElementSetMessagingTimeout(element, 0.3)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value
    }

    private func focused(_ app: NSRunningApplication) -> AXUIElement? {
        guard let value = attribute(AXUIElementCreateApplication(app.processIdentifier), kAXFocusedUIElementAttribute),
              CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    private func selectedRange(_ element: AXUIElement) -> CFRange? {
        guard let value = attribute(element, kAXSelectedTextRangeAttribute), CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var range = CFRange()
        return AXValueGetValue(value as! AXValue, .cfRange, &range) ? range : nil
    }

    private func select(_ element: AXUIElement, _ range: CFRange) -> Bool {
        var range = range
        guard let value = AXValueCreate(.cfRange, &range) else { return false }
        return AXUIElementSetAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, value) == .success
    }

    private func bounds(of range: CFRange, in element: AXUIElement) -> NSRect? {
        var range = range
        guard let parameter = AXValueCreate(.cfRange, &range) else { return nil }
        var value: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(element, kAXBoundsForRangeParameterizedAttribute as CFString, parameter, &value) == .success,
              let value, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var rect = CGRect.zero
        guard AXValueGetValue(value as! AXValue, .cgRect, &rect), rect.width > 0 || rect.height > 0 else { return nil }
        return rect
    }

    private func isEditable(_ element: AXUIElement) -> Bool {
        for name in [kAXSelectedTextAttribute, kAXValueAttribute] {
            var settable: DarwinBoolean = false
            if AXUIElementIsAttributeSettable(element, name as CFString, &settable) == .success, settable.boolValue { return true }
        }
        let role = attribute(element, kAXRoleAttribute) as? String ?? ""
        return [kAXTextFieldRole, kAXTextAreaRole, kAXComboBoxRole].contains(role)
    }

    private func isSecure(_ element: AXUIElement?) -> Bool {
        guard let element else { return false }
        return attribute(element, kAXSubroleAttribute) as? String == kAXSecureTextFieldSubrole
    }

    private func isFrontmost(_ app: NSRunningApplication) -> Bool {
        !app.isTerminated && NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier
    }

    private func sameFocus(as source: TextSelectionSource) -> Bool {
        matchesFocus(source.element, in: source.app)
    }

    private func matchesFocus(_ element: AXUIElement?, in app: NSRunningApplication) -> Bool {
        // A nonactivating panel can take keyboard focus without changing the frontmost application.
        // Check the system-wide focus too, so synthetic copy/paste cannot land in that panel.
        guard let global = attribute(AXUIElementCreateSystemWide(), kAXFocusedUIElementAttribute),
              CFGetTypeID(global) == AXUIElementGetTypeID() else { return false }
        let globalElement = global as! AXUIElement
        var pid: pid_t = 0
        guard AXUIElementGetPid(globalElement, &pid) == .success, pid == app.processIdentifier else { return false }
        guard let element else { return true }
        guard let current = focused(app) else { return false }
        return CFEqual(current, element) && CFEqual(globalElement, element)
    }

    private func same(_ lhs: CFRange?, _ rhs: CFRange) -> Bool {
        lhs.map { $0.location == rhs.location && $0.length == rhs.length } ?? false
    }

    private func valid(_ range: CFRange, in text: String) -> Bool {
        range.location >= 0 && range.length >= 0 && range.location <= text.utf16.count && range.length <= text.utf16.count - range.location
    }

    private func substring(_ text: String, range: CFRange) -> String? {
        guard valid(range, in: text) else { return nil }
        return (text as NSString).substring(with: NSRange(location: range.location, length: range.length))
    }

    private func replacing(_ text: String, range: CFRange, with replacement: String) -> String? {
        guard valid(range, in: text) else { return nil }
        return (text as NSString).replacingCharacters(in: NSRange(location: range.location, length: range.length), with: replacement)
    }

    private func clipboardSnapshot(_ pasteboard: NSPasteboard) -> [NSPasteboardItem]? {
        var copies: [NSPasteboardItem] = []
        for item in pasteboard.pasteboardItems ?? [] {
            let copy = NSPasteboardItem()
            for type in item.types {
                guard let data = item.data(forType: type), copy.setData(data, forType: type) else { return nil }
            }
            copies.append(copy)
        }
        return copies
    }

    private func clipboardAvailable(_ pasteboard: NSPasteboard) -> Bool {
        if #available(macOS 15.4, *), pasteboard.accessBehavior == .alwaysDeny { return false }
        return true
    }

    private func restore(_ items: [NSPasteboardItem], to pasteboard: NSPasteboard) {
        pasteboard.clearContents()
        if !items.isEmpty { pasteboard.writeObjects(items) }
    }

    private func issue(_ text: String) -> TextSelectionError { .message(text) }
}
