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
    /// Whisper language code for files, dictation and notes. `auto` asks Whisper to detect it.
    @Published var spokenLanguage: String { didSet { defaults.set(spokenLanguage, forKey: "spokenLanguage") } }
    /// Language for the next note only. Cleared when that note starts.
    @Published var nextNoteLanguage: String?
    /// Model id from `TranscriptionModel.catalog` used by dictation and notes.
    @Published var liveModel: String { didSet { defaults.set(liveModel, forKey: "liveModel") } }
    /// Optional words and names passed to Whisper as a prompt.
    @Published var vocabulary: String { didSet { defaults.set(vocabulary, forKey: "vocabulary") } }
    @Published var residency: ModelResidency { didSet { defaults.set(residency.rawValue, forKey: "residency") } }
    /// Menu bar override that keeps the model loaded regardless of `residency`.
    @Published var keepReady: Bool { didSet { defaults.set(keepReady, forKey: "keepReady") } }
    @Published var noteSources: NoteSources { didSet { defaults.set(noteSources.rawValue, forKey: "noteSources") } }
    @Published var noteVocabulary: String { didSet { defaults.set(noteVocabulary, forKey: "noteVocabulary") } }
    @Published var keepNoteAudio: Bool { didSet { defaults.set(keepNoteAudio, forKey: "keepNoteAudio") } }
    @Published var automaticAudioBoost: Bool { didSet { defaults.set(automaticAudioBoost, forKey: "automaticAudioBoost") } }
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
        spokenLanguage = defaults.string(forKey: "spokenLanguage") ?? Self.initialLanguage(defaults)
        liveModel = defaults.string(forKey: "liveModel") ?? "turbo"
        vocabulary = defaults.string(forKey: "vocabulary") ?? ""
        residency = ModelResidency(rawValue: defaults.string(forKey: "residency") ?? "") ?? .tenMinutes
        keepReady = bool("keepReady", false)
        noteSources = NoteSources(rawValue: defaults.string(forKey: "noteSources") ?? "") ?? .both
        noteVocabulary = defaults.string(forKey: "noteVocabulary") ?? ""
        keepNoteAudio = bool("keepNoteAudio", true)
        automaticAudioBoost = bool("automaticAudioBoost", true)
        showInDock = bool("showInDock", true)
        defaults.set(spokenLanguage, forKey: "spokenLanguage")
    }
    var model: TranscriptionModel { TranscriptionModel.catalog.first { $0.id == liveModel } ?? TranscriptionModel.catalog[4] }
    var noteLanguage: String { nextNoteLanguage ?? spokenLanguage }

    /// Versions before 2.3 kept separate file, dictation and note languages. The first explicit one wins,
    /// then the Mac's language when Whisper supports it.
    static func initialLanguage(_ defaults: UserDefaults, preferred: [String] = Locale.preferredLanguages) -> String {
        let supported = Set(AppStore.languages.map(\.0)).subtracting(["auto"])
        for key in ["language", "dictationLanguage", "noteLanguage"] {
            if let code = defaults.string(forKey: key), supported.contains(code) { return code }
        }
        for identifier in preferred {
            if let code = Locale(identifier: identifier).language.languageCode?.identifier, supported.contains(code) { return code }
        }
        return "auto"
    }
}
