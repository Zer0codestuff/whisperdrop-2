import AppKit
import Combine
import Sparkle
import WhisperDropCore

@MainActor
final class AppUpdater: NSObject, ObservableObject, SPUUpdaterDelegate {
    @Published private(set) var canCheck = false
    @Published private(set) var automaticallyChecks = false
    @Published private(set) var status = "Updates are available in packaged releases."
    @Published private(set) var deferred = false
    @Published private(set) var availableVersion: String?
    @Published private(set) var activity = UpdateActivity()
    private var controller: SPUStandardUpdaterController?
    private var observations: Set<AnyCancellable> = []
    private var pendingInstall: (() -> Void)?
    private var retryTask: Task<Void, Never>?
    var currentActivity: () -> UpdateActivity = { UpdateActivity() }
    var prepareToRestart: () throws -> Void = {}

    func start(bundle: Bundle = .main) {
        guard controller == nil, bundle.object(forInfoDictionaryKey: "CFBundlePackageType") as? String == "APPL" else { return }
        do {
            _ = try UpdateConfiguration(feed: bundle.object(forInfoDictionaryKey: "SUFeedURL") as? String ?? "",
                                        publicKey: bundle.object(forInfoDictionaryKey: "SUPublicEDKey") as? String ?? "",
                                        verification: bundle.bundleIdentifier == UpdateConfiguration.verificationBundleID)
            let controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: self, userDriverDelegate: nil)
            self.controller = controller
            try controller.updater.start()
            controller.updater.publisher(for: \.canCheckForUpdates).sink { [weak self] in self?.canCheck = $0 }.store(in: &observations)
            controller.updater.publisher(for: \.automaticallyChecksForUpdates).sink { [weak self] in self?.automaticallyChecks = $0 }.store(in: &observations)
            status = "Checks official WhisperDrop releases. Installation always asks you first."
        } catch { status = error.localizedDescription; controller = nil }
    }

    func observe(_ publishers: [AnyPublisher<Void, Never>]) {
        Publishers.MergeMany(publishers).sink { [weak self] in
            Task { @MainActor [weak self] in self?.activity = self?.currentActivity() ?? UpdateActivity() }
        }.store(in: &observations)
        activity = currentActivity()
    }

    func check() {
        guard canCheck, activity.blockingReason == nil else { return }
        status = "Checking for updates…"
        controller?.checkForUpdates(nil)
    }

    func setAutomaticChecks(_ enabled: Bool) { controller?.updater.automaticallyChecksForUpdates = enabled }

    func updater(_ updater: SPUUpdater, mayPerform updateCheck: SPUUpdateCheck) throws {
        if let reason = currentActivity().blockingReason {
            throw NSError(domain: "WhisperDrop.Updates", code: 2, userInfo: [NSLocalizedDescriptionKey: reason])
        }
    }

    func updater(_ updater: SPUUpdater, shouldPostponeRelaunchForUpdate item: SUAppcastItem, untilInvokingBlock installHandler: @escaping () -> Void) -> Bool {
        deferRestart(installHandler)
        return true
    }

    /// Keep Sparkle's installation handler until active work and the durable draft save finish.
    func deferRestart(_ installHandler: @escaping () -> Void) {
        pendingInstall = installHandler; deferred = true
        retryDeferredInstall()
    }

    func retryDeferredInstall() {
        retryTask?.cancel(); retryTask = nil
        guard let install = pendingInstall else { return }
        if let reason = currentActivity().blockingReason {
            status = reason + " The update will restart the app when it is ready."
            retryTask = Task { [weak self] in
                do { try await Task.sleep(for: .seconds(1)); try Task.checkCancellation() } catch { return }
                self?.retryDeferredInstall()
            }
            return
        }
        do { try prepareToRestart() }
        catch { status = "Could not save your draft. The update is waiting. " + error.localizedDescription; return }
        pendingInstall = nil; deferred = false; status = "Installing update…"
        install()
    }

    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        availableVersion = item.displayVersionString
        status = "WhisperDrop \(item.displayVersionString) is available."
    }
    func updaterDidNotFindUpdate(_ updater: SPUUpdater) { status = "You have the latest available version." }
    func updater(_ updater: SPUUpdater, didAbortWithError error: Error) {
        handleUpdateError(error)
    }
    func handleUpdateError(_ error: Error) {
        retryTask?.cancel(); pendingInstall = nil; deferred = false
        let error = error as NSError
        if error.domain == SUSparkleErrorDomain && error.code == Int(SUError.noUpdateError.rawValue) {
            status = "You have the latest available version."
        } else if error.domain == SUSparkleErrorDomain && error.code == Int(SUError.installationCanceledError.rawValue) {
            status = "Update canceled. Your current version is unchanged."
        } else { status = "The update could not complete. " + error.localizedDescription }
    }
    func allowedSystemProfileKeys(for updater: SPUUpdater) -> [String]? { [] }
}
