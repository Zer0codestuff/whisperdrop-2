import XCTest
@testable import WhisperDropCore

final class TextContextTests: XCTestCase {
    func testAutomaticContextFitsShortEditsAndBoundsLongNotesByMemory() throws {
        let grammar = try XCTUnwrap(TextAction.action(id: "grammar"))
        let summary = try XCTUnwrap(TextAction.action(id: "summary"))
        let memory: UInt64 = 8 * 1_073_741_824
        XCTAssertEqual(TextContextPolicy.context(mode: .automatic, inputTokens: 200, promptOverhead: 300,
            action: grammar, modelMaximum: 128000, physicalMemoryBytes: memory), 8192)
        XCTAssertEqual(TextContextPolicy.context(mode: .automatic, inputTokens: 10000, promptOverhead: 300,
            action: summary, modelMaximum: 128000, physicalMemoryBytes: memory), 8192)
        XCTAssertEqual(TextContextPolicy.context(mode: .automatic, inputTokens: 50000, promptOverhead: 300,
            action: summary, modelMaximum: 128000, physicalMemoryBytes: memory), 8192)
        XCTAssertEqual(TextContextPolicy.context(mode: .automatic, inputTokens: 20000, promptOverhead: 300,
            action: summary, modelMaximum: 128000, physicalMemoryBytes: 16 * 1_073_741_824), 16384)
    }

    func testBudgetsReserveCompleteOutputsAndNeverOverflowAnyTier() {
        for action in TextAction.defaults {
            for context in [8192, 16384, 32768] {
                for overhead in [150, 1400, 7900, 40000] {
                    let input = TextContextPolicy.inputBudget(contextTokens: context, promptOverhead: overhead, action: action)
                    guard input > 0 else { continue }
                    let output = TextContextPolicy.outputTokens(inputTokens: input, action: action)
                    XCTAssertLessThanOrEqual(input + output + overhead + TextContextPolicy.safetyTokens, context,
                        "\(action.id), context \(context), instruction \(overhead)")
                }
            }
        }
    }

    func testExplicitContextAndHardwareLimitsRespectModelMaximum() throws {
        let summary = try XCTUnwrap(TextAction.action(id: "summary"))
        XCTAssertEqual(TextContextPolicy.context(mode: .large, inputTokens: 10, promptOverhead: 100,
            action: summary, modelMaximum: 128000, physicalMemoryBytes: 8 * 1_073_741_824), 32768)
        XCTAssertEqual(TextContextPolicy.context(mode: .large, inputTokens: 10, promptOverhead: 100,
            action: summary, modelMaximum: 8192, physicalMemoryBytes: 8 * 1_073_741_824), 8192)
        XCTAssertEqual(TextContextPolicy.automaticMaximum(physicalMemoryBytes: 4 * 1_073_741_824), 8192)
        XCTAssertEqual(TextContextPolicy.automaticMaximum(physicalMemoryBytes: 8 * 1_073_741_824), 8192)
        XCTAssertEqual(TextContextPolicy.automaticMaximum(physicalMemoryBytes: 12 * 1_073_741_824), 16384)
        XCTAssertEqual(TextContextPolicy.automaticMaximum(physicalMemoryBytes: 16 * 1_073_741_824), 16384)
        XCTAssertEqual(TextContextPolicy.automaticMaximum(physicalMemoryBytes: 24 * 1_073_741_824), 32768)
        XCTAssertEqual(TextContextPolicy.inputBudget(contextTokens: 8192, promptOverhead: 9000, action: summary), 0)
    }
}
