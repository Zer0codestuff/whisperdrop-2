import Foundation

/// Contract file. Inserts text into the focused app.
@MainActor
enum TextInserter {
    /// Places `text` on the pasteboard and, if `paste` is true and Accessibility is granted, sends Cmd+V.
    /// Restores the previous pasteboard contents afterwards when `restoreClipboard` is true.
    /// Returns true if the text was pasted, false if it was only copied.
    @discardableResult
    static func insert(_ text: String, paste: Bool, restoreClipboard: Bool) async -> Bool { false }
    /// True when secure input (password fields) is active and pasting would not work.
    static var secureInputActive: Bool { false }
}
