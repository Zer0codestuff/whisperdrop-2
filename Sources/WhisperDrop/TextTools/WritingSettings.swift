import Foundation
import WhisperDropCore

@MainActor
final class WritingSettings: ObservableObject {
    private let defaults: UserDefaults
    @Published var modelID: String { didSet { defaults.set(modelID, forKey: "writing.modelID") } }
    @Published var contextMode: TextContextMode { didSet { defaults.set(contextMode.rawValue, forKey: "writing.contextMode") } }
    @Published var actions: [TextAction] { didSet { save(actions, key: "writing.actions") } }
    @Published var showAfterDictation: Bool { didSet { defaults.set(showAfterDictation, forKey: "writing.showAfterDictation") } }
    @Published var autoSummarizeNotes: Bool { didSet { defaults.set(autoSummarizeNotes, forKey: "writing.autoSummarizeNotes") } }
    @Published var shortcut: String { didSet { defaults.set(shortcut, forKey: "writing.shortcut") } }
    @Published var style: String { didSet { defaults.set(style, forKey: "writing.style") } }
    @Published var styleExamples: [String] { didSet { save(styleExamples, key: "writing.styleExamples") } }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let id = defaults.string(forKey: "writing.modelID") ?? "lfm2.5-2.6b"
        modelID = TextModel.catalog.contains(where: { $0.id == id }) ? id : "lfm2.5-2.6b"
        contextMode = TextContextMode(rawValue: defaults.string(forKey: "writing.contextMode") ?? "") ?? .automatic
        if let data = defaults.data(forKey: "writing.actions"), let saved = try? JSONDecoder().decode([TextAction].self, from: data) {
            // Recover blank or duplicate actions, and add new built-ins when updating the app.
            var seen = Set<String>()
            let restored = saved.filter { !$0.id.isEmpty && !$0.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && seen.insert($0.id).inserted }
            actions = restored + TextAction.defaults.filter { !seen.contains($0.id) }
        } else { actions = TextAction.defaults }
        showAfterDictation = defaults.object(forKey: "writing.showAfterDictation") as? Bool ?? true
        autoSummarizeNotes = defaults.object(forKey: "writing.autoSummarizeNotes") as? Bool ?? false
        let shortcut = defaults.string(forKey: "writing.shortcut") ?? "control-option-d"
        self.shortcut = Self.shortcuts.contains(shortcut) ? shortcut : "control-option-d"
        style = defaults.string(forKey: "writing.style") ?? "Keep my voice. Prefer clear, direct sentences. Avoid corporate language. Never use em dashes."
        if let data = defaults.data(forKey: "writing.styleExamples"), let values = try? JSONDecoder().decode([String].self, from: data) { styleExamples = Array(values.suffix(8)) }
        else { styleExamples = [] }
    }

    static let shortcuts = ["control-option-d", "command-shift-d", "control-option-space"]
    var shortcutLabel: String {
        switch shortcut {
        case "command-shift-d": "⇧⌘D"
        case "control-option-space": "⌃⌥Space"
        default: "⌃⌥D"
        }
    }
    func action(id: String) -> TextAction? { actions.first { $0.id == id } ?? TextAction.action(id: id) }
    func resetActions() { actions = TextAction.defaults }
    func rememberStyle(_ text: String) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        styleExamples = Array((styleExamples.filter { $0 != text } + [text]).suffix(8))
    }
    private func save<T: Encodable>(_ value: T, key: String) {
        if let data = try? JSONEncoder().encode(value) { defaults.set(data, forKey: key) }
    }
}
