import XCTest
import Darwin
import WhisperDropCore
@testable import WhisperDrop

@MainActor
final class WritingSettingsTests: XCTestCase {
    func testWritingPreferencesPersistWithoutChangingSpeechPreferences() throws {
        let suite = "WhisperDropWritingTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("turbo", forKey: "mainModel")
        let settings = WritingSettings(defaults: defaults)
        XCTAssertEqual(settings.modelID, "lfm2.5-2.6b")
        XCTAssertEqual(settings.contextMode, .automatic)
        XCTAssertTrue(settings.showAfterDictation)
        XCTAssertFalse(settings.autoSummarizeNotes)
        settings.modelID = "minicpm5-1b"; settings.showAfterDictation = false; settings.autoSummarizeNotes = true
        settings.shortcut = "command-shift-d"; settings.style = "Preserve technical terms."
        settings.contextMode = .large
        settings.actions[0].title = "Proofread"; settings.actions[0].instruction = "Keep line breaks."
        settings.rememberStyle("A short example.")
        settings.rememberStyle("A short example.")
        let again = WritingSettings(defaults: defaults)
        XCTAssertEqual(again.modelID, "minicpm5-1b")
        XCTAssertFalse(again.showAfterDictation); XCTAssertTrue(again.autoSummarizeNotes)
        XCTAssertEqual(again.shortcut, "command-shift-d")
        XCTAssertEqual(again.contextMode, .large)
        XCTAssertEqual(again.style, "Preserve technical terms.")
        XCTAssertEqual(again.action(id: "grammar")?.title, "Proofread")
        XCTAssertEqual(again.action(id: "grammar")?.instruction, "Keep line breaks.")
        XCTAssertEqual(again.styleExamples, ["A short example."])
        XCTAssertEqual(defaults.string(forKey: "mainModel"), "turbo")
    }

    func testCorruptActionsRecoverAndStyleExamplesAreBounded() throws {
        let suite = "WhisperDropWritingTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let duplicate = TextAction(id: "grammar", title: "Proofread", instruction: "Preserve formulas.")
        defaults.set(try JSONEncoder().encode([duplicate, duplicate]), forKey: "writing.actions")
        defaults.set("unknown", forKey: "writing.modelID")
        defaults.set("unknown", forKey: "writing.shortcut")
        defaults.set("unknown", forKey: "writing.contextMode")
        let settings = WritingSettings(defaults: defaults)
        XCTAssertEqual(settings.actions.count, TextAction.defaults.count)
        XCTAssertEqual(settings.actions.first?.title, "Proofread")
        XCTAssertEqual(settings.modelID, "lfm2.5-2.6b")
        XCTAssertEqual(settings.shortcut, "control-option-d")
        XCTAssertEqual(settings.contextMode, .automatic)
        for index in 0..<12 { settings.rememberStyle("Example \(index)") }
        XCTAssertEqual(settings.styleExamples.count, 8)
        XCTAssertEqual(settings.styleExamples.first, "Example 4")
        defaults.set(Data("broken json".utf8), forKey: "writing.actions")
        XCTAssertEqual(WritingSettings(defaults: defaults).actions, TextAction.defaults)
    }

    func testRealTextModelOnDemandGenerationAndUnload() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let modelPath = environment["WHISPERDROP_TEST_TEXT_MODEL"], let runtimePath = environment["WHISPERDROP_TEST_TEXT_RUNTIME"] else {
            throw XCTSkip("Set WHISPERDROP_TEST_TEXT_MODEL and WHISPERDROP_TEST_TEXT_RUNTIME for the optional local text-model check.")
        }
        let id = environment["WHISPERDROP_TEST_TEXT_MODEL_ID"] ?? "lfm2.5-2.6b"
        let model = try XCTUnwrap(TextModel.catalog.first { $0.id == id })
        let pidFile = FileManager.default.temporaryDirectory.appendingPathComponent("text-engine-\(UUID().uuidString).pid")
        let engine = TextGenerationEngine(runtime: { URL(fileURLWithPath: runtimePath) }, processFile: pidFile)
        defer { engine.unload(); try? FileManager.default.removeItem(at: pidFile) }
        XCTAssertEqual(engine.state, .off)
        let result = try await engine.generate(text: "She don't have time today.", action: try XCTUnwrap(TextAction.action(id: "grammar")), model: model, file: URL(fileURLWithPath: modelPath))
        XCTAssertTrue(result.contains("doesn't") || result.contains("does not"), result)
        XCTAssertFalse(result.contains("<think>")); XCTAssertFalse(result.contains("<|"))
        XCTAssertEqual(engine.loadedModelID, id)
        XCTAssertFalse(engine.isGenerating)
        var cases: [[String: String]] = [["action": "grammar", "source": "She don't have time today.", "output": result]]
        if id == "lfm2.5-2.6b" {
            let source = "Ieri abbiamo ricevuto i documenti e lo abbiamo controllati. La consegna resta fissata per venerdì."
            let corrected = try await engine.generate(text: source, action: try XCTUnwrap(TextAction.action(id: "grammar")), model: model, file: URL(fileURLWithPath: modelPath))
            XCTAssertTrue(corrected.contains("li abbiamo controllati"), corrected)
            XCTAssertTrue(corrected.contains("resta fissata per venerdì"), corrected)
            cases.append(["action": "grammar", "source": source, "output": corrected])
        }
        // These are synthetic quality probes, recorded for review rather than used to claim language accuracy.
        for (actionID, source) in [
            ("natural", "Ciao, puoi mandarmi il report quando hai un attimo? Mi serve per domani."),
            ("summary", environment["WHISPERDROP_TEST_TEXT_SUMMARY"] ?? "The team met on Tuesday. Maya will send the report on Wednesday. The launch is planned for Thursday.")
        ] {
            do {
                let output = try await engine.generate(text: source, action: try XCTUnwrap(TextAction.action(id: actionID)), model: model, file: URL(fileURLWithPath: modelPath))
                cases.append(["action": actionID, "source": source, "output": output])
            } catch { cases.append(["action": actionID, "source": source, "error": error.localizedDescription]) }
        }
        if let reportPath = environment["WHISPERDROP_TEST_TEXT_REPORT"] {
            let report: [String: Any] = ["model": id, "cases": cases, "qualityScope": "Synthetic spot checks only; review output facts and language manually."]
            let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: URL(fileURLWithPath: reportPath), options: .atomic)
        }
        let pid = try XCTUnwrap(engine.processID)
        engine.unload()
        for _ in 0..<30 {
            if kill(pid, 0) != 0 { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertNotEqual(kill(pid, 0), 0, "Unloading must release the model process")
        XCTAssertEqual(engine.state, .off)
    }
}
