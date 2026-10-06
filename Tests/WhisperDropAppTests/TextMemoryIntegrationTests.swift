import Foundation
import Darwin
import XCTest
import WhisperDropCore
@testable import WhisperDrop

@MainActor
final class TextMemoryIntegrationTests: XCTestCase {
    private struct Fixture: Decodable {
        let text: String
        let instruction: String?
    }

    private struct Sample: Codable {
        let elapsedSeconds: Double
        let phase: String
        let testResidentBytes: UInt64?
        let speechResidentBytes: UInt64?
        let textResidentBytes: UInt64?
        let speechAlive: Bool
        let textAlive: Bool
    }

    private struct Report: Codable {
        let speechModel: String
        let textModel: String
        let contextMode: String
        let actualPhysicalMemoryBytes: UInt64
        let sourceWords: Int
        let note: String
        var speechLoadSeconds: Double?
        var summaryElapsedSeconds: Double?
        var summary: String?
        var summaryWords: Int?
        var metrics: TextGenerationMetrics?
        var speechStayedResident = false
        var pendingGenerationCancelled = false
        var speechProcessExited = false
        var textProcessExited = false
        var peakTestResidentBytes: UInt64?
        var peakSpeechResidentBytes: UInt64?
        var peakTextResidentBytes: UInt64?
        var swapUsedMBBefore: Double?
        var swapUsedMBAfter: Double?
        var error: String?
        var samples: [Sample] = []
    }

    /// Opt-in only. Loads real speech weights, keeps that server resident while summarizing,
    /// then cancels another generation and verifies that both child processes exit.
    func testSummaryWithResidentSpeechModelAndCancellation() async throws {
        executionTimeAllowance = 360
        let env = ProcessInfo.processInfo.environment
        guard let speechPath = env["WHISPERDROP_MEMORY_SPEECH_MODEL"],
              let speechRuntimePath = env["WHISPERDROP_MEMORY_SPEECH_RUNTIME"],
              let textPath = env["WHISPERDROP_TEST_TEXT_MODEL"],
              let textRuntimePath = env["WHISPERDROP_TEST_TEXT_RUNTIME"],
              let fixturePath = env["WHISPERDROP_MEMORY_TEXT_FIXTURE"],
              let reportPath = env["WHISPERDROP_MEMORY_REPORT"] else {
            throw XCTSkip("Set isolated speech/text model, runtime, synthetic fixture and memory report paths for this opt-in test.")
        }
        let speechModel = try XCTUnwrap(TranscriptionModel.catalog.first {
            $0.id == (env["WHISPERDROP_MEMORY_SPEECH_MODEL_ID"] ?? "parakeet-v3")
        })
        let textModel = try XCTUnwrap(TextModel.catalog.first {
            $0.id == (env["WHISPERDROP_TEST_TEXT_MODEL_ID"] ?? "lfm2.5-2.6b")
        })
        let mode = try XCTUnwrap(TextContextMode(rawValue: env["WHISPERDROP_MEMORY_CONTEXT"] ?? "automatic"))
        let speechFile = URL(fileURLWithPath: speechPath)
        let speechRuntime = URL(fileURLWithPath: speechRuntimePath, isDirectory: true)
        let textFile = URL(fileURLWithPath: textPath)
        let textRuntime = URL(fileURLWithPath: textRuntimePath)
        let fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: URL(fileURLWithPath: fixturePath)))
        let action = try XCTUnwrap(TextAction.action(id: "summary"))
        let reportURL = URL(fileURLWithPath: reportPath).standardizedFileURL.resolvingSymlinksInPath()
        let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let reportRoots = [repository.appendingPathComponent(".experiments", isDirectory: true), FileManager.default.temporaryDirectory]
        guard reportRoots.contains(where: { reportURL.path.hasPrefix($0.standardizedFileURL.resolvingSymlinksInPath().path + "/") }) else {
            throw XCTSkip("Write the memory report inside ignored .experiments or the temporary directory, outside the user's library.")
        }
        XCTAssertFalse(fixture.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        try XCTSkipUnless(FileManager.default.isReadableFile(atPath: speechFile.path), "The speech model fixture is missing.")
        try XCTSkipUnless(FileManager.default.isReadableFile(atPath: textFile.path), "The text model fixture is missing.")
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: speechRuntime.appendingPathComponent(speechModel.engine.serverName).path), "The speech runtime fixture is missing.")
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: textRuntime.path), "The text runtime fixture is missing.")

        // Do not instantiate AppStore or use the app's normal PID files, defaults or library.
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("WhisperDrop-memory-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        let host = ModelHost(tool: { speechRuntime.appendingPathComponent($0) },
            modelFile: { requested in
                guard requested.id == speechModel.id else { throw AppFailure("This test has only one speech model fixture.") }
                return speechFile
            }, processFile: scratch.appendingPathComponent("speech.pid"))
        let engine = TextGenerationEngine(runtime: { textRuntime }, processFile: scratch.appendingPathComponent("text.pid"))
        host.keepReady = true
        host.residency = .always
        var speechPID: Int32?
        var textPID: Int32?
        var pending: Task<String, Error>?
        var phase = "loading-speech"
        var samples: [Sample] = []
        let started = Date()
        let sampler = Task { @MainActor in
            while !Task.isCancelled {
                let speech = host.serverProcessIdentifier
                let text = engine.processID
                samples.append(Sample(elapsedSeconds: Date().timeIntervalSince(started), phase: phase,
                    testResidentBytes: residentBytes(getpid()), speechResidentBytes: speech.flatMap(residentBytes),
                    textResidentBytes: text.flatMap(residentBytes), speechAlive: speech.map(isAlive) ?? false,
                    textAlive: text.map(isAlive) ?? false))
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
        defer {
            pending?.cancel(); sampler.cancel(); engine.unload(); host.shutdown()
            try? FileManager.default.removeItem(at: scratch)
        }
        var report = Report(speechModel: speechModel.id, textModel: textModel.id, contextMode: mode.rawValue,
            actualPhysicalMemoryBytes: ProcessInfo.processInfo.physicalMemory,
            sourceWords: fixture.text.split(whereSeparator: \.isWhitespace).count,
            note: "Synthetic Italian summary with a loaded, idle speech server. This does not test recording or simultaneous speech inference. RSS includes mapped/shared pages and cannot be summed as total system or GPU memory. Peaks use 100 ms sampling and can miss short spikes. Swap is system-wide. Only the recorded physical Mac was tested; no 16 GB hardware is simulated.")
        report.swapUsedMBBefore = swapUsedMB()
        do {
            let loadStarted = Date()
            try await host.ensureReady(speechModel)
            report.speechLoadSeconds = Date().timeIntervalSince(loadStarted)
            speechPID = try XCTUnwrap(host.serverProcessIdentifier)
            XCTAssertEqual(host.state, .ready)
            XCTAssertTrue(isAlive(speechPID!))
            phase = "generating-summary"
            let summaryStarted = Date()
            let summary = try await engine.generate(text: fixture.text, action: action,
                instruction: fixture.instruction ?? "", model: textModel, file: textFile, context: mode)
            report.summaryElapsedSeconds = Date().timeIntervalSince(summaryStarted)
            report.summary = summary
            report.summaryWords = summary.split(whereSeparator: \.isWhitespace).count
            report.metrics = engine.lastRun
            textPID = try XCTUnwrap(engine.processID)
            XCTAssertFalse(summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            XCTAssertFalse(summary.contains("<think>")); XCTAssertFalse(summary.contains("<|"))
            XCTAssertEqual(host.serverProcessIdentifier, speechPID, "Writing must leave the resident speech server alive.")
            XCTAssertEqual(host.state, .ready)
            report.speechStayedResident = isAlive(speechPID!)
            XCTAssertTrue(report.speechStayedResident)
            XCTAssertEqual(engine.lastRun?.contextTokens, engine.loadedContextTokens)
            XCTAssertGreaterThan(engine.lastRun?.inputTokens ?? 0, 0)

            phase = "cancelling-generation"
            pending = Task { @MainActor in
                try await engine.generate(text: fixture.text, action: action,
                    instruction: fixture.instruction ?? "", model: textModel, file: textFile, context: mode)
            }
            for _ in 0..<100 {
                if engine.isGenerating { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            XCTAssertTrue(engine.isGenerating, "Observe an active request before checking cancellation.")
            pending?.cancel(); engine.unload(); host.shutdown()
            do {
                _ = try await pending!.value
                XCTFail("A cancelled generation must not return a suggestion.")
            } catch {
                let cancelled = error is CancellationError ||
                    ((error as NSError).domain == NSURLErrorDomain && (error as NSError).code == NSURLErrorCancelled)
                XCTAssertTrue(cancelled, "Expected cancellation, got \(error.localizedDescription)")
                report.pendingGenerationCancelled = cancelled
            }
            pending = nil
            report.speechProcessExited = try await waitForExit(speechPID!)
            report.textProcessExited = try await waitForExit(textPID!)
            XCTAssertTrue(report.speechProcessExited, "The speech child must exit after shutdown.")
            XCTAssertTrue(report.textProcessExited, "The text child must exit after unload.")
            XCTAssertEqual(host.state, .unloaded)
            XCTAssertEqual(engine.state, .off)
            XCTAssertFalse(engine.isGenerating)
            phase = "stopped"
        } catch {
            report.error = error.localizedDescription
            if textPID == nil { textPID = engine.processID }
            pending?.cancel(); engine.unload(); host.shutdown()
            if let speechPID { report.speechProcessExited = (try? await waitForExit(speechPID)) ?? false }
            if let textPID { report.textProcessExited = (try? await waitForExit(textPID)) ?? false }
            sampler.cancel(); await sampler.value
            finishReport(&report, samples: samples)
            try JSONEncoder().encode(report).write(to: reportURL, options: .atomic)
            throw error
        }
        sampler.cancel(); await sampler.value
        finishReport(&report, samples: samples)
        XCTAssertGreaterThan(report.peakSpeechResidentBytes ?? 0, 0)
        XCTAssertGreaterThan(report.peakTextResidentBytes ?? 0, 0)
        try JSONEncoder().encode(report).write(to: reportURL, options: .atomic)
    }

    private func finishReport(_ report: inout Report, samples: [Sample]) {
        report.samples = samples
        report.peakTestResidentBytes = samples.compactMap(\.testResidentBytes).max()
        report.peakSpeechResidentBytes = samples.compactMap(\.speechResidentBytes).max()
        report.peakTextResidentBytes = samples.compactMap(\.textResidentBytes).max()
        report.swapUsedMBAfter = swapUsedMB()
    }

    private func residentBytes(_ pid: Int32) -> UInt64? {
        var info = proc_taskinfo()
        guard proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &info, Int32(MemoryLayout<proc_taskinfo>.size)) > 0 else { return nil }
        return info.pti_resident_size
    }

    private func isAlive(_ pid: Int32) -> Bool { pid > 0 && kill(pid, 0) == 0 }

    private func waitForExit(_ pid: Int32) async throws -> Bool {
        for _ in 0..<60 {
            if !isAlive(pid) { return true }
            try await Task.sleep(for: .milliseconds(100))
        }
        return !isAlive(pid)
    }

    private func swapUsedMB() -> Double? {
        let process = Process(); let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/sysctl"); process.arguments = ["-n", "vm.swapusage"]
        process.standardOutput = pipe; process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        process.waitUntilExit()
        guard let match = output.range(of: #"used = [0-9.]+M"#, options: .regularExpression) else { return nil }
        return Double(output[match].dropFirst(7).dropLast())
    }
}
