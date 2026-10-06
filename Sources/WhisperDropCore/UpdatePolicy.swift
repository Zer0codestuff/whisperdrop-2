import Foundation

/// Work that must finish before an update can restart the app.
public struct UpdateActivity: Equatable, Sendable {
    public var recording = false
    public var dictating = false
    public var transcribing = false
    public var importing = false
    public var movingFiles = false
    public var downloadingModel = false
    public var editing = false
    public var replacingText = false
    public var reviewingSelection = false
    public init() {}
    public var blockingReason: String? {
        if recording { return "Finish recording before updating." }
        if dictating { return "Finish dictation before updating." }
        if transcribing || importing { return "Wait for transcription and imports to finish before updating." }
        if movingFiles { return "Wait for saved files to finish moving before updating." }
        if downloadingModel { return "Wait for the model download to finish before updating." }
        if replacingText || editing { return "Wait for the writing action to finish before updating." }
        if reviewingSelection { return "Finish or close the writing review panel before updating." }
        return nil
    }
}

public struct UpdateConfiguration: Equatable, Sendable {
    public static let bundleID = "io.github.zer0codestuff.whisperdrop2"
    public static let verificationBundleID = bundleID + ".updater-verification"
    public let feedURL: URL
    public let publicKey: String

    public init(feed: String, publicKey: String, verification: Bool = false) throws {
        guard let url = URL(string: feed), let host = url.host, !host.isEmpty,
              url.user == nil, url.password == nil, url.fragment == nil,
              url.scheme == "https" || (verification && url.scheme == "http" && ["127.0.0.1", "localhost", "::1"].contains(host)),
              let key = Data(base64Encoded: publicKey), key.count == 32 else {
            throw NSError(domain: "WhisperDrop.Updates", code: 1, userInfo: [NSLocalizedDescriptionKey: "This build has no valid signed update configuration."])
        }
        feedURL = url; self.publicKey = publicKey
    }
}
