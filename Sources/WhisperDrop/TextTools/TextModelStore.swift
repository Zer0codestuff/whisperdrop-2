import Foundation
import AppKit
import UniformTypeIdentifiers

struct TextModel: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let detail: String
    let fileName: String
    let url: URL
    let sha256: String
    let bytes: Int64
    let maximumContextTokens: Int
    var size: String { ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) }

    // File sizes and SHA-256 are the LFS metadata for these pinned publisher revisions.
    static let catalog: [Self] = [
        .init(id: "lfm2.5-2.6b", name: "LFM2.5 2.6B", detail: "Local multilingual writing model. QAD Q4_0, up to 128K model context.",
              fileName: "LFM2.5-2.6B-QAD-Q4_0.gguf",
              url: URL(string: "https://huggingface.co/LiquidAI/LFM2.5-2.6B-GGUF/resolve/e7caca5d835a3901a8e0d63e94009429bafafdfc/LFM2.5-2.6B-QAD-Q4_0.gguf")!,
              sha256: "a247afd6414918eac8e520a9e6137dc271235461ecbe1180462221d5b8d40b03", bytes: 1_593_894_944, maximumContextTokens: 128000),
        .init(id: "minicpm5-1b", name: "MiniCPM5 1B", detail: "Experimental smaller model. Q4_K_M, up to 128K model context. Quality varies by language.",
              fileName: "MiniCPM5-1B-Q4_K_M.gguf",
              url: URL(string: "https://huggingface.co/openbmb/MiniCPM5-1B-GGUF/resolve/075694439cc4b49f0fdf565c7e99e72d8ef29379/MiniCPM5-1B-Q4_K_M.gguf")!,
              sha256: "81b64d05a23b17b34c475f42b3e72fbde62d4b92cc34541f7a8031d0752deafa", bytes: 688_065_920, maximumContextTokens: 131072)
    ]
}

@MainActor
final class TextModelStore: ObservableObject {
    let folder: URL
    let catalog = TextModel.catalog
    @Published private(set) var installed: Set<String> = []
    @Published private(set) var downloadingID: String?
    @Published private(set) var progress: Double = 0
    @Published var error: String?
    private var work: Task<Void, Never>?
    private var installation: Task<Void, Error>?
    private var installationID = UUID()
    private var transferID = UUID()

    init(folder: URL) { self.folder = folder; refresh() }
    func model(id: String) -> TextModel? { catalog.first { $0.id == id } }
    func location(for model: TextModel) -> URL { folder.appendingPathComponent(model.fileName) }
    func isInstalled(_ model: TextModel) -> Bool { installed.contains(model.id) }
    func refresh() {
        installed = Set(catalog.filter { model in
            let attributes = try? FileManager.default.attributesOfItem(atPath: location(for: model).path)
            return (attributes?[.size] as? NSNumber)?.int64Value == model.bytes
        }.map(\.id))
    }

    func download(_ model: TextModel) {
        guard downloadingID == nil, !isInstalled(model) else { return }
        let id = UUID(); transferID = id; downloadingID = model.id; progress = 0; error = nil
        work = Task { [weak self] in
            guard let self else { return }
            defer { if self.transferID == id { self.downloadingID = nil; self.work = nil } }
            var staged: URL?
            defer { if let staged { try? FileManager.default.removeItem(at: staged) } }
            do {
                let download = ModelTransfer { [weak self] value in
                    Task { @MainActor in if self?.transferID == id { self?.progress = value * 0.95 } }
                }
                let file = try await download.download(model.url); staged = file
                try Task.checkCancellation()
                try await self.install(file, model: model)
                guard self.transferID == id else { return }
                self.progress = 1; self.refresh()
            } catch is CancellationError {} catch {
                if self.transferID == id { self.error = error.localizedDescription }
            }
        }
    }

    func cancelDownload() {
        transferID = UUID(); work?.cancel(); installation?.cancel(); work = nil; downloadingID = nil; progress = 0
    }

    /// Import the same published model, for example an existing Draft download. The source is preserved.
    func chooseFile(for model: TextModel) {
        guard downloadingID == nil else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [UTType(filenameExtension: "gguf") ?? .data]
        panel.prompt = "Use model"
        panel.message = "Choose \(model.fileName). WhisperDrop verifies and copies the model; your original file stays where it is."
        panel.begin { [weak self] result in
            guard result == .OK, let source = panel.url else { return }
            Task { @MainActor in await self?.importFile(source, for: model) }
        }
    }

    func importFile(_ source: URL, for model: TextModel) async {
        guard downloadingID == nil else { return }
        let id = UUID(); transferID = id; downloadingID = model.id; progress = 0; error = nil
        defer { if transferID == id { downloadingID = nil; work = nil } }
        do { try await install(source, model: model); if transferID == id { progress = 1; refresh() } }
        catch is CancellationError {} catch { if transferID == id { self.error = error.localizedDescription } }
    }

    private func install(_ source: URL, model: TextModel) async throws {
        let folder = folder, destination = location(for: model)
        let id = UUID(); installationID = id
        let task = Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            guard try sha256File(source) == model.sha256 else { throw AppFailure("This model does not match the published checksum for \(model.name). Download it again or choose the matching GGUF file.") }
            try Task.checkCancellation()
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            if source.standardizedFileURL == destination.standardizedFileURL { return }
            let staged = folder.appendingPathComponent(".text-model-\(UUID().uuidString).partial")
            defer { try? FileManager.default.removeItem(at: staged) }
            try FileManager.default.copyItem(at: source, to: staged)
            try Task.checkCancellation()
            guard try sha256File(staged) == model.sha256 else { throw AppFailure("The copied model failed verification. Your existing model is unchanged.") }
            try Task.checkCancellation()
            if FileManager.default.fileExists(atPath: destination.path) {
                _ = try FileManager.default.replaceItemAt(destination, withItemAt: staged)
            } else { try FileManager.default.moveItem(at: staged, to: destination) }
        }
        installation = task
        defer { if installationID == id { installation = nil } }
        try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }
}
