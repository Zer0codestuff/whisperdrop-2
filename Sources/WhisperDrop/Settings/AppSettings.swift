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

/// What a model is used for. Each task follows the main model unless Settings, Models gives it its own.
enum ModelTask: String, CaseIterable, Identifiable {
    case dictation, notes, files
    var id: String { rawValue }
    var label: String {
        switch self {
        case .dictation: "Dictation"
        case .notes: "Notes"
        case .files: "Files and YouTube"
        }
    }
    var shortLabel: String { self == .files ? "files" : rawValue }
    fileprivate var key: String { rawValue + "Model" }
}

/// Where dictation shows words while you speak. Only fast engines (Parakeet) provide them.
enum DictationLiveText: String, CaseIterable, Identifiable {
    /// Typed into the focused text field and corrected while you speak.
    case inField
    /// Shown in the dictation bar only. The text is inserted when you finish.
    case bar
    case off
    var id: String { rawValue }
    var label: String {
        switch self {
        case .inField: "In the text field"
        case .bar: "In the dictation bar"
        case .off: "Off"
        }
    }
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
    /// Model id from `TranscriptionModel.catalog`. Every task uses it unless it has its own model.
    @Published var mainModel: String { didSet { defaults.set(mainModel, forKey: "mainModel") } }
    /// Per-task model ids. A missing entry follows `mainModel`.
    @Published private(set) var taskModels: [ModelTask: String] = [:]
    /// Optional words and names passed to Whisper as a prompt.
    @Published var vocabulary: String { didSet { defaults.set(vocabulary, forKey: "vocabulary") } }
    /// When the resident model unloads. `.always` is Keep model ready, in Settings and in the menu bar.
    @Published var residency: ModelResidency { didSet { defaults.set(residency.rawValue, forKey: "residency") } }
    @Published var noteSources: NoteSources { didSet { defaults.set(noteSources.rawValue, forKey: "noteSources") } }
    @Published var noteVocabulary: String { didSet { defaults.set(noteVocabulary, forKey: "noteVocabulary") } }
    @Published var keepNoteAudio: Bool { didSet { defaults.set(keepNoteAudio, forKey: "keepNoteAudio") } }
    @Published var automaticAudioBoost: Bool { didSet { defaults.set(automaticAudioBoost, forKey: "automaticAudioBoost") } }
    @Published var showInDock: Bool { didSet { defaults.set(showInDock, forKey: "showInDock") } }
    @Published var dictationLiveText: DictationLiveText { didSet { defaults.set(dictationLiveText.rawValue, forKey: "dictationLiveText") } }
    /// Unconfirmed words after the transcript while a note records.
    @Published var noteLiveText: Bool { didSet { defaults.set(noteLiveText, forKey: "noteLiveText") } }

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
        // Before 2.5 the main window chose the file model ("model") and Settings chose the dictation and note model
        // ("liveModel"). The Settings choice becomes the one model.
        mainModel = Self.known(defaults.string(forKey: "mainModel")) ?? Self.known(defaults.string(forKey: "liveModel"))
            ?? Self.known(defaults.string(forKey: "model")) ?? "turbo"
        var own: [ModelTask: String] = [:]
        for task in ModelTask.allCases {
            if let id = Self.known(defaults.string(forKey: task.key)) { own[task] = id }
        }
        taskModels = own
        vocabulary = defaults.string(forKey: "vocabulary") ?? ""
        var residency = ModelResidency(rawValue: defaults.string(forKey: "residency") ?? "") ?? .tenMinutes
        if defaults.bool(forKey: "keepReady"), residency != .always {
            // Keep model ready was a separate switch before 2.5. It is now the `.always` residency.
            defaults.set(residency.rawValue, forKey: "residencyBeforeKeepReady")
            residency = .always
        }
        self.residency = residency
        noteSources = NoteSources(rawValue: defaults.string(forKey: "noteSources") ?? "") ?? .both
        noteVocabulary = defaults.string(forKey: "noteVocabulary") ?? ""
        keepNoteAudio = bool("keepNoteAudio", true)
        automaticAudioBoost = bool("automaticAudioBoost", true)
        showInDock = bool("showInDock", true)
        let livePreview = bool("livePreview", true)
        dictationLiveText = DictationLiveText(rawValue: defaults.string(forKey: "dictationLiveText") ?? "") ?? (livePreview ? .inField : .off)
        noteLiveText = bool("noteLiveText", livePreview)
        defaults.set(spokenLanguage, forKey: "spokenLanguage")
        defaults.set(mainModel, forKey: "mainModel")
        defaults.set(residency.rawValue, forKey: "residency")
        defaults.removeObject(forKey: "keepReady")
    }

    private static func known(_ id: String?) -> String? {
        id.flatMap { id in TranscriptionModel.catalog.contains { $0.id == id } ? id : nil }
    }

    /// The main model.
    var model: TranscriptionModel { Self.catalogModel(mainModel) }
    func model(for task: ModelTask) -> TranscriptionModel { Self.catalogModel(taskModels[task] ?? mainModel) }
    /// The task's own model id, or nil when it follows the main model.
    func ownModel(for task: ModelTask) -> String? { taskModels[task] }
    func setOwnModel(_ id: String?, for task: ModelTask) {
        let value = id == mainModel ? nil : Self.known(id)
        taskModels[task] = value
        if let value { defaults.set(value, forKey: task.key) } else { defaults.removeObject(forKey: task.key) }
    }
    private static func catalogModel(_ id: String) -> TranscriptionModel {
        TranscriptionModel.catalog.first { $0.id == id } ?? TranscriptionModel.catalog.first { $0.id == "turbo" }!
    }

    /// Menu bar shortcut for the Keep model ready residency. Turning it off restores the previous choice.
    var keepReady: Bool {
        get { residency == .always }
        set {
            guard newValue != keepReady else { return }
            if newValue {
                defaults.set(residency.rawValue, forKey: "residencyBeforeKeepReady")
                residency = .always
            } else {
                let previous = ModelResidency(rawValue: defaults.string(forKey: "residencyBeforeKeepReady") ?? "") ?? .tenMinutes
                residency = previous == .always ? .tenMinutes : previous
            }
        }
    }
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
