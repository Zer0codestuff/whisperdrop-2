import Foundation
import WhisperDropCore

enum HotkeyChoice: String, CaseIterable, Identifiable {
    case fn, rightOption, rightCommand, rightControl
    var id: String { rawValue }
    var label: String {
        switch self {
        case .fn: "fn (Globe)"
        case .rightOption: "Right Option"
        case .rightCommand: "Right Command"
        case .rightControl: "Right Control"
        }
    }
}

enum DictationMode: String, CaseIterable, Identifiable {
    /// Hold to talk; double-tap starts hands-free mode, tap again to stop.
    case holdOrDoubleTap
    case hold
    /// Tap to start, tap to stop.
    case toggle
    var id: String { rawValue }
    var label: String {
        switch self {
        case .holdOrDoubleTap: "Hold to talk, double-tap for hands-free"
        case .hold: "Hold to talk"
        case .toggle: "Tap to start and stop"
        }
    }
}

enum NoteSources: String, CaseIterable, Identifiable {
    case microphone, systemAudio, both
    var id: String { rawValue }
    var label: String {
        switch self {
        case .microphone: "Microphone"
        case .systemAudio: "System audio"
        case .both: "Microphone and system audio"
        }
    }
    var usesMicrophone: Bool { self != .systemAudio }
    var usesSystemAudio: Bool { self != .microphone }
}

/// User preferences backed by UserDefaults.
@MainActor
final class AppSettings: ObservableObject {
    private let defaults: UserDefaults
    @Published var dictationEnabled: Bool { didSet { defaults.set(dictationEnabled, forKey: "dictationEnabled") } }
    @Published var hotkey: HotkeyChoice { didSet { defaults.set(hotkey.rawValue, forKey: "hotkey") } }
    @Published var dictationMode: DictationMode { didSet { defaults.set(dictationMode.rawValue, forKey: "dictationMode") } }
    @Published var autoPaste: Bool { didSet { defaults.set(autoPaste, forKey: "autoPaste") } }
    @Published var restoreClipboard: Bool { didSet { defaults.set(restoreClipboard, forKey: "restoreClipboard") } }
    @Published var sounds: Bool { didSet { defaults.set(sounds, forKey: "sounds") } }
    @Published var dictationLanguage: String { didSet { defaults.set(dictationLanguage, forKey: "dictationLanguage") } }
    /// Model id from `TranscriptionModel.catalog` used by dictation and notes.
    @Published var liveModel: String { didSet { defaults.set(liveModel, forKey: "liveModel") } }
    /// Optional words and names passed to Whisper as a prompt.
    @Published var vocabulary: String { didSet { defaults.set(vocabulary, forKey: "vocabulary") } }
    @Published var residency: ModelResidency { didSet { defaults.set(residency.rawValue, forKey: "residency") } }
    /// Menu bar override that keeps the model loaded regardless of `residency`.
    @Published var keepReady: Bool { didSet { defaults.set(keepReady, forKey: "keepReady") } }
    @Published var noteSources: NoteSources { didSet { defaults.set(noteSources.rawValue, forKey: "noteSources") } }
    @Published var noteLanguage: String { didSet { defaults.set(noteLanguage, forKey: "noteLanguage") } }
    @Published var noteVocabulary: String { didSet { defaults.set(noteVocabulary, forKey: "noteVocabulary") } }
    @Published var keepNoteAudio: Bool { didSet { defaults.set(keepNoteAudio, forKey: "keepNoteAudio") } }
    @Published var showInDock: Bool { didSet { defaults.set(showInDock, forKey: "showInDock") } }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        func bool(_ key: String, _ fallback: Bool) -> Bool { defaults.object(forKey: key) as? Bool ?? fallback }
        dictationEnabled = bool("dictationEnabled", true)
        hotkey = HotkeyChoice(rawValue: defaults.string(forKey: "hotkey") ?? "") ?? .fn
        dictationMode = DictationMode(rawValue: defaults.string(forKey: "dictationMode") ?? "") ?? .holdOrDoubleTap
        autoPaste = bool("autoPaste", true)
        restoreClipboard = bool("restoreClipboard", true)
        sounds = bool("sounds", true)
        dictationLanguage = defaults.string(forKey: "dictationLanguage") ?? "auto"
        liveModel = defaults.string(forKey: "liveModel") ?? "turbo"
        vocabulary = defaults.string(forKey: "vocabulary") ?? ""
        residency = ModelResidency(rawValue: defaults.string(forKey: "residency") ?? "") ?? .tenMinutes
        keepReady = bool("keepReady", false)
        noteSources = NoteSources(rawValue: defaults.string(forKey: "noteSources") ?? "") ?? .both
        noteLanguage = defaults.string(forKey: "noteLanguage") ?? "auto"
        noteVocabulary = defaults.string(forKey: "noteVocabulary") ?? ""
        keepNoteAudio = bool("keepNoteAudio", true)
        showInDock = bool("showInDock", true)
    }
    var model: TranscriptionModel { TranscriptionModel.catalog.first { $0.id == liveModel } ?? TranscriptionModel.catalog[4] }
}
