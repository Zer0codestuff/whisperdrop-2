import Foundation
import CryptoKit
import Darwin

struct AppFailure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
    init(_ message: String) { self.message = message }
}

struct CommandResult { let stdout: String; let stderr: String; let status: Int32 }

@MainActor
final class CommandRunner {
    func run(_ executable: URL, _ arguments: [String], timeout: TimeInterval? = nil, progress: ((String) -> Void)? = nil) async throws -> CommandResult {
        try Task.checkCancellation()
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let outURL = folder.appendingPathComponent("stdout")
        let errURL = folder.appendingPathComponent("stderr")
        FileManager.default.createFile(atPath: outURL.path, contents: nil)
        FileManager.default.createFile(atPath: errURL.path, contents: nil)
        let out = try FileHandle(forWritingTo: outURL), err = try FileHandle(forWritingTo: errURL)
        let reader = try FileHandle(forReadingFrom: errURL)
        defer { try? out.close(); try? err.close(); try? reader.close() }
        let process = Process()
        process.executableURL = executable; process.arguments = arguments
        process.standardOutput = out; process.standardError = err
        process.standardInput = FileHandle.nullDevice
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = executable.deletingLastPathComponent().path + ":/usr/bin:/bin:/usr/sbin:/sbin"
        environment["LC_ALL"] = "en_US.UTF-8"
        process.environment = environment
        try process.run()
        let started = Date()
        do {
            while process.isRunning {
                if let timeout, Date().timeIntervalSince(started) > timeout { throw AppFailure("The local audio tool took too long to respond.") }
                try await Task.sleep(for: .milliseconds(150))
                if let data = try reader.readToEnd(), !data.isEmpty {
                    progress?(String(decoding: data, as: UTF8.self))
                }
            }
            try Task.checkCancellation()
        } catch {
            if process.isRunning {
                process.terminate()
                for _ in 0..<10 {
                    if !process.isRunning { break }
                    try? await Task.sleep(nanoseconds: 50_000_000)
                }
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            }
            throw error
        }
        let stdout = String(decoding: try Data(contentsOf: outURL), as: UTF8.self)
        let stderr = String(decoding: try Data(contentsOf: errURL), as: UTF8.self)
        return CommandResult(stdout: stdout, stderr: stderr, status: process.terminationStatus)
    }
}

final class ModelTransfer: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<URL, Error>?
    private var task: URLSessionDownloadTask?
    private var session: URLSession?
    private var cancelled = false
    private var saved: URL?
    private var transferError: Error?
    let onProgress: @Sendable (Double) -> Void
    init(onProgress: @escaping @Sendable (Double) -> Void) { self.onProgress = onProgress }
    func download(_ url: URL) async throws -> URL {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                if cancelled { lock.unlock(); continuation.resume(throwing: CancellationError()); return }
                self.continuation = continuation
                let config = URLSessionConfiguration.ephemeral
                config.timeoutIntervalForRequest = 60
                let session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
                self.session = session
                let task = session.downloadTask(with: url)
                self.task = task
                lock.unlock()
                task.resume()
            }
        } onCancel: { self.cancel() }
    }
    private func cancel() {
        lock.lock(); cancelled = true; let task = task; lock.unlock()
        task?.cancel()
    }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        if totalBytesExpectedToWrite > 0 { onProgress(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)) }
    }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        do {
            guard let response = downloadTask.response as? HTTPURLResponse, (200..<300).contains(response.statusCode) else {
                throw AppFailure("The model server returned an error. Try the download again.")
            }
            let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".model")
            try FileManager.default.moveItem(at: location, to: path)
            saved = path
        } catch { transferError = error }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock(); let continuation = continuation; self.continuation = nil; let cancelled = cancelled; lock.unlock()
        if let error = transferError ?? error {
            if let saved { try? FileManager.default.removeItem(at: saved) }
            continuation?.resume(throwing: cancelled ? CancellationError() : error)
        } else if let saved {
            if cancelled { try? FileManager.default.removeItem(at: saved); continuation?.resume(throwing: CancellationError()) }
            else { continuation?.resume(returning: saved) }
        } else { continuation?.resume(throwing: AppFailure("The model download did not finish.")) }
        session.finishTasksAndInvalidate()
        self.session = nil
    }
}

func sha256File(_ url: URL) throws -> String {
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    var hash = SHA256()
    while let data = try handle.read(upToCount: 1024 * 1024), !data.isEmpty { hash.update(data: data) }
    return hash.finalize().map { String(format: "%02x", $0) }.joined()
}
