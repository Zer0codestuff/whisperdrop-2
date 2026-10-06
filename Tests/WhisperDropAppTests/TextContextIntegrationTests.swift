import XCTest
import Darwin
import WhisperDropCore
@testable import WhisperDrop

@MainActor
final class TextContextIntegrationTests: XCTestCase {
    private struct Fixture: Decodable {
        let id: String
        let action: String
        let text: String
        let instruction: String
        let profiles: [String]
        let requiredPatterns: [String]
        let forbiddenPatterns: [String]
    }
    private struct Result: Codable {
        let profile: String
        let fixture: String
        let output: String?
        let error: String?
        let missingPatterns: [String]
        let forbiddenMatches: [String]
        let metrics: TextGenerationMetrics?
        let warmModel: Bool
        let swapUsedMBBefore: Double?
        let swapUsedMBAfter: Double?
    }
    private struct Report: Codable {
        let model: String
        let actualMemoryBytes: UInt64
        let note: String
        var results: [Result]
        var cancellationReleasedProcess = false
    }

    func testLocalContextComparisonAndCancellation() async throws {
        executionTimeAllowance = 1800
        let env = ProcessInfo.processInfo.environment
        guard let fixturePath = env["WHISPERDROP_TEXT_CONTEXT_FIXTURES"],
              let modelPath = env["WHISPERDROP_TEST_TEXT_MODEL"],
              let runtimePath = env["WHISPERDROP_TEST_TEXT_RUNTIME"],
              let reportPath = env["WHISPERDROP_TEXT_CONTEXT_REPORT"] else {
            throw XCTSkip("Set local model, runtime, context fixtures and report paths for the opt-in context comparison.")
        }
        let model = try XCTUnwrap(TextModel.catalog.first { $0.id == (env["WHISPERDROP_TEST_TEXT_MODEL_ID"] ?? "lfm2.5-2.6b") })
        let fixtures = try JSONDecoder().decode([Fixture].self, from: Data(contentsOf: URL(fileURLWithPath: fixturePath)))
        let reportURL = URL(fileURLWithPath: reportPath)
        var report = Report(model: model.id, actualMemoryBytes: ProcessInfo.processInfo.physicalMemory,
            note: "Synthetic Italian context probes. The automatic-16gb profile simulates selection policy only; execution still uses the actual Mac. RSS is not total system or GPU memory. Swap readings are system-wide.", results: [])
        func save() throws { try JSONEncoder().encode(report).write(to: reportURL, options: .atomic) }
        let requested = env["WHISPERDROP_TEXT_CONTEXT_PROFILES"]?.components(separatedBy: ",")
        let profiles: [(String, TextContextMode, UInt64)] = [
            ("8k", .small, ProcessInfo.processInfo.physicalMemory),
            ("16k", .medium, ProcessInfo.processInfo.physicalMemory),
            ("32k", .large, ProcessInfo.processInfo.physicalMemory),
            ("automatic", .automatic, ProcessInfo.processInfo.physicalMemory),
            ("automatic-16gb", .automatic, 16 * 1_073_741_824)
        ].filter { requested == nil || requested!.contains($0.0) }
        for (profile, mode, memory) in profiles {
            let pidFile = FileManager.default.temporaryDirectory.appendingPathComponent("text-context-\(UUID().uuidString).pid")
            let engine = TextGenerationEngine(runtime: { URL(fileURLWithPath: runtimePath) }, processFile: pidFile, physicalMemoryBytes: memory)
            defer { engine.unload(); try? FileManager.default.removeItem(at: pidFile) }
            for fixture in fixtures where fixture.profiles.contains(profile) {
                let action = try XCTUnwrap(TextAction.action(id: fixture.action))
                let warm = engine.loadedModelID != nil
                let swapBefore = swapUsedMB()
                var output: String?, failure: String?
                do {
                    output = try await engine.generate(text: fixture.text, action: action, instruction: fixture.instruction,
                        model: model, file: URL(fileURLWithPath: modelPath), context: mode)
                    XCTAssertFalse(output!.contains("<think>")); XCTAssertFalse(output!.contains("<|"))
                    if let fixed = mode.fixedTokens { XCTAssertEqual(engine.lastRun?.contextTokens, fixed) }
                    XCTAssertGreaterThan(engine.lastRun?.inputTokens ?? 0, 0)
                    XCTAssertGreaterThan(engine.lastRun?.inputChunks ?? 0, 0)
                } catch {
                    failure = error.localizedDescription
                    if profile == "automatic" {
                        XCTAssertTrue(engine.state == .ready || engine.state == .off, "A failed action must leave an idle or unloaded model: \(failure!)")
                        XCTAssertFalse(engine.isGenerating)
                    }
                }
                let text = output ?? ""
                let missing = fixture.requiredPatterns.filter { text.range(of: $0, options: [.regularExpression, .caseInsensitive]) == nil }
                let forbidden = fixture.forbiddenPatterns.filter { text.range(of: $0, options: [.regularExpression, .caseInsensitive]) != nil }
                report.results.append(.init(profile: profile, fixture: fixture.id, output: output, error: failure,
                    missingPatterns: missing, forbiddenMatches: forbidden, metrics: engine.lastRun, warmModel: warm,
                    swapUsedMBBefore: swapBefore, swapUsedMBAfter: swapUsedMB()))
                try save()
                print("Context probe: \(model.id), \(profile), \(fixture.id), \(failure == nil ? "complete" : "rejected"), missing checks \(missing.count)")
            }
            if profile == "automatic", let source = fixtures.first(where: { $0.action == "summary" }) {
                let pid = try XCTUnwrap(engine.processID)
                let task = Task {
                    try await engine.generate(text: source.text, action: try XCTUnwrap(TextAction.action(id: "summary")),
                        model: model, file: URL(fileURLWithPath: modelPath), context: .automatic)
                }
                try await Task.sleep(for: .milliseconds(250))
                task.cancel(); engine.unload()
                do { _ = try await task.value; XCTFail("Cancelled generation must not return a suggestion") }
                catch { XCTAssertTrue(error is CancellationError, "\(error)") }
                try await waitForExit(pid)
                XCTAssertFalse(engine.isGenerating)
                report.cancellationReleasedProcess = true
                try save()
            } else if let pid = engine.processID {
                engine.unload(); try await waitForExit(pid)
            }
        }
        XCTAssertFalse(report.results.isEmpty)
        try save()
    }

    private func waitForExit(_ pid: Int32) async throws {
        for _ in 0..<40 {
            if kill(pid, 0) != 0 { return }
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertNotEqual(kill(pid, 0), 0, "Unloading must release the model process")
    }

    private func swapUsedMB() -> Double? {
        let p = Process(); let pipe = Pipe()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/sysctl"); p.arguments = ["-n", "vm.swapusage"]
        p.standardOutput = pipe; p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return nil }
        let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        p.waitUntilExit()
        guard let match = output.range(of: #"used = [0-9.]+M"#, options: .regularExpression) else { return nil }
        return Double(output[match].dropFirst(7).dropLast())
    }
}
