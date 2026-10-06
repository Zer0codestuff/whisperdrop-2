import XCTest
@testable import WhisperDropCore

final class TextToolsTests: XCTestCase {
    func testOutputRejectsReasoningToolCallsAndAnswers() throws {
        let grammar = try XCTUnwrap(TextAction.action(id: "grammar"))
        XCTAssertEqual(try TextToolRequest.cleanOutput("Hidden reasoning</think>She doesn't have time.", original: "She don't have time.", action: grammar), "She doesn't have time.")
        XCTAssertEqual(try TextToolRequest.cleanOutput("Here is the corrected text:\n\nShe doesn't have time. (Corrected subject agreement.)", original: "She don't have time.", action: grammar), "She doesn't have time.")
        for raw in ["<think>Incomplete", "<|tool_call_start|>edit()", "You're welcome!", "Sure, I will write that poem.", "I will send it tomorrow.", ""] {
            XCTAssertThrowsError(try TextToolRequest.cleanOutput(raw, original: "Could you send the file?", action: grammar))
        }
        XCTAssertEqual(try TextToolRequest.cleanOutput("Call me (after lunch).", original: "Call me (after lunch)", action: grammar), "Call me (after lunch).")
        XCTAssertEqual(TextToolRequest.preservingEdgeWhitespace("Corrected text.", of: " Original text.\n\n"), " Corrected text.\n\n")
    }

    func testEditedActionInstructionsReachThePromptAndNotesKeepTheirHeadings() throws {
        var action = try XCTUnwrap(TextAction.action(id: "organize"))
        action.instruction = "Use headings and keep mathematical formulas."
        let request = TextToolRequest(text: "Equazione e prossimo incontro", action: action, instruction: "Keep it in Italian", style: "Use direct sentences")
        XCTAssertTrue(request.userPrompt.contains(action.instruction))
        XCTAssertTrue(request.userPrompt.contains("Keep it in Italian"))
        XCTAssertEqual(request.language, "Italian")
        XCTAssertTrue(request.userPrompt.contains("Use direct sentences"))
        XCTAssertEqual(request.systemPrompt, "")
        let organized = "Meeting notes:\n\nCall on Friday."
        XCTAssertEqual(try TextToolRequest.cleanOutput(organized, original: "Meeting call on Friday", action: action), organized)
        XCTAssertEqual(TextAction.defaults.map(\.id), ["grammar", "natural", "tone", "rewrite", "summary", "organize", "concise"])
        var grammar = try XCTUnwrap(TextAction.action(id: "grammar"))
        grammar.instruction = "Keep mathematical formulas unchanged."
        let italian = TextToolRequest(text: "Ieri abbiamo ricevuto i documenti e lo abbiamo controllati.", action: grammar, instruction: "Keep every name.")
        XCTAssertEqual(italian.language, "Italian")
        XCTAssertTrue(italian.userPrompt.contains(grammar.instruction))
        XCTAssertTrue(italian.userPrompt.contains("Keep every name."))
    }

    func testLongTextChunksKeepEveryCharacterAndRespectMeasuredBudget() async throws {
        let text = (0..<60).map { "Paragraph \($0): Caffè 👋 and a decision on Friday.\n\n" }.joined()
        // A synthetic tokenizer gives Unicode/emoji more weight than an ASCII byte guess would.
        func tokens(_ text: String) -> Int { text.unicodeScalars.reduce(0) { $0 + ($1.isASCII ? 1 : 3) } }
        let chunks = try await TextToolChunks.split(text, maximumTokens: 140) { tokens($0) }
        XCTAssertGreaterThan(chunks.count, 1)
        XCTAssertEqual(chunks.joined(), text)
        XCTAssertTrue(chunks.allSatisfy { tokens($0) <= 140 && !$0.isEmpty })
        let short = try await TextToolChunks.split("Short text", maximumTokens: 140) { tokens($0) }
        XCTAssertEqual(short, ["Short text"])
    }

    func testSummaryRejectsNearlyCompleteRewritesAndSetsAnExplicitBudget() throws {
        let source = (0..<100).map { "word\($0)" }.joined(separator: " ")
        let rewrite = (0..<90).map { "revised\($0)" }.joined(separator: " ")
        let summary = (0..<30).map { "point\($0)" }.joined(separator: " ")
        XCTAssertEqual(TextToolRequest.summaryWordLimit(for: source), 35)
        XCTAssertTrue(TextToolRequest.summaryIsTooLong(rewrite, original: source))
        XCTAssertFalse(TextToolRequest.summaryIsTooLong(summary, original: source))
        let request = TextToolRequest(text: source, action: try XCTUnwrap(TextAction.action(id: "summary")), style: "Private writing example")
        XCTAssertTrue(request.systemPrompt.contains("at most 35 words"))
        XCTAssertTrue(request.userPrompt.contains("at most 35 words"))
        XCTAssertFalse(request.userPrompt.contains("Private writing example"))
    }
}
