import XCTest
import Darwin
import WhisperDropCore
@testable import WhisperDrop

@MainActor
final class TextEngineLifecycleTests: XCTestCase {
    func testLengthStoppedSummaryRetriesOriginalOnceAndNeverReturnsPartialText() async throws {
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/python3") else {
            throw XCTSkip("The fake local runtime requires /usr/bin/python3.")
        }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("text-summary-recovery-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let runtime = folder.appendingPathComponent("llama-server")
        try Self.fakeRuntime.write(to: runtime, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: runtime.path)
        let modelFile = folder.appendingPathComponent("synthetic-model.gguf")
        try Data("Synthetic summary fixture, not model weights.".utf8).write(to: modelFile)
        let model = try XCTUnwrap(TextModel.catalog.first { $0.id == "lfm2.5-2.6b" })
        let summary = try XCTUnwrap(TextAction.action(id: "summary"))
        let engine = TextGenerationEngine(runtime: { runtime }, processFile: folder.appendingPathComponent("server.pid"))
        defer { engine.unload() }
        let source = "SUMMARY_RECOVERY. The team decided Aurora launches Friday. Maya checks the report before launch."
        let result = try await engine.generate(text: source, action: summary, model: model, file: modelFile)
        XCTAssertEqual(result, "Aurora launches Friday. Maya checks the report.")
        XCTAssertFalse(result.contains("Never publish"))
        XCTAssertEqual(engine.lastRun?.completionRequests, 2, "The original source must be retried exactly once.")

        do {
            _ = try await engine.generate(text: "SUMMARY_ALWAYS_LENGTH. Aurora launches Friday. Keep this original note intact.", action: summary, model: model, file: modelFile)
            XCTFail("Two incomplete responses must not become a replacement suggestion.")
        } catch {
            XCTAssertTrue(error.localizedDescription.lowercased().contains("unchanged"))
        }
        XCTAssertEqual(engine.lastRun?.completionRequests, 2, "Incomplete summaries must not cause an unbounded retry loop.")
        let pid = try XCTUnwrap(engine.processID)
        engine.unload()
        try await waitForExit(pid)
    }

    func testTimedOutRequestReleasesServerAndTheNextActionStartsFresh() async throws {
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/python3") else {
            throw XCTSkip("The fake local runtime requires /usr/bin/python3.")
        }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("text-engine-lifecycle-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let runtime = folder.appendingPathComponent("llama-server")
        try Self.fakeRuntime.write(to: runtime, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: runtime.path)
        let modelFile = folder.appendingPathComponent("synthetic-model.gguf")
        try Data("Synthetic test fixture, not model weights.".utf8).write(to: modelFile)
        let model = try XCTUnwrap(TextModel.catalog.first { $0.id == "lfm2.5-2.6b" })
        let grammar = try XCTUnwrap(TextAction.action(id: "grammar"))
        let pidFile = folder.appendingPathComponent("text-engine.pid")
        let engine = TextGenerationEngine(runtime: { runtime }, processFile: pidFile, completionTimeout: 0.3)
        defer { engine.unload() }

        // Capture the owned process while the fake model delays only this completion.
        let slow = Task { try await engine.generate(text: "Slow probe: keep this original text.", action: grammar, model: model, file: modelFile) }
        var firstPID: Int32?
        for _ in 0..<100 {
            if let pid = engine.processID { firstPID = pid; break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let timedOutPID = try XCTUnwrap(firstPID)
        do {
            _ = try await slow.value
            XCTFail("A timed-out action must not return a replacement suggestion.")
        } catch {
            let message = error.localizedDescription.lowercased()
            XCTAssertTrue(message.contains("timed out") || message.contains("too long"), message)
            XCTAssertTrue(message.contains("unchanged"), "The timeout must tell the user their original text is unchanged: \(message)")
        }
        XCTAssertEqual(engine.state, .off)
        XCTAssertNil(engine.processID)
        XCTAssertFalse(engine.isGenerating)
        XCTAssertFalse(FileManager.default.fileExists(atPath: pidFile.path))

        // A new server must serve this request immediately, without the abandoned slow request ahead of it.
        let revised = try await engine.generate(text: "She don't have time today.", action: grammar, model: model, file: modelFile)
        XCTAssertEqual(revised, "She doesn't have time today.")
        XCTAssertNotEqual(kill(timedOutPID, 0), 0, "A fresh server must wait for the abandoned server to release its allocation.")
        XCTAssertEqual(engine.state, .ready)
        let freshPID = try XCTUnwrap(engine.processID)
        XCTAssertNotEqual(freshPID, timedOutPID)
        _ = try await engine.generate(text: "She don't have time today.", action: grammar, model: model, file: modelFile, context: .large)
        XCTAssertEqual(engine.loadedContextTokens, 32768)
        let largePID = try XCTUnwrap(engine.processID)
        _ = try await engine.generate(text: "She don't have time today.", action: grammar, model: model, file: modelFile, context: .automatic)
        XCTAssertLessThanOrEqual(engine.loadedContextTokens ?? Int.max,
            TextContextPolicy.automaticMaximum(physicalMemoryBytes: ProcessInfo.processInfo.physicalMemory))
        let finalPID = try XCTUnwrap(engine.processID)
        engine.unload()
        try await waitForExit(finalPID)
        try await waitForExit(largePID)
        try await waitForExit(freshPID)
        XCTAssertEqual(engine.state, .off)
    }

    private func waitForExit(_ pid: Int32) async throws {
        for _ in 0..<40 {
            if kill(pid, 0) != 0 { return }
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertNotEqual(kill(pid, 0), 0, "The test's owned runtime must exit and release its pending request.")
    }

    private static let fakeRuntime = #"""
    #!/usr/bin/python3
    import argparse
    import json
    import signal
    import time
    from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

    parser = argparse.ArgumentParser(add_help=False)
    parser.add_argument('--port', type=int, required=True)
    parser.add_argument('--api-key', required=True)
    args, _ = parser.parse_known_args()
    # Exercise the forced-shutdown path rather than an instant default SIGTERM exit.
    signal.signal(signal.SIGTERM, signal.SIG_IGN)
    summary_attempts = {}

    class Handler(BaseHTTPRequestHandler):
        def log_message(self, *_):
            pass

        def send_json(self, value, status=200):
            data = json.dumps(value).encode()
            try:
                self.send_response(status)
                self.send_header('Content-Type', 'application/json')
                self.send_header('Content-Length', str(len(data)))
                self.end_headers()
                self.wfile.write(data)
            except (BrokenPipeError, ConnectionResetError):
                pass

        def authorized(self):
            if self.headers.get('Authorization') == 'Bearer ' + args.api_key:
                return True
            self.send_json({'error': 'Unauthorized'}, 401)
            return False

        def do_GET(self):
            if self.authorized():
                self.send_json({'status': 'ok'})

        def do_POST(self):
            if not self.authorized():
                return
            body = json.loads(self.rfile.read(int(self.headers.get('Content-Length', '0'))))
            if self.path == '/tokenize':
                content = body.get('content', '')
                if body.get('with_pieces'):
                    self.send_json({'tokens': [{'id': 1, 'piece': content}]})
                else:
                    self.send_json({'tokens': [1] * max(1, len(content.split()))})
                return
            if self.path == '/v1/chat/completions':
                messages = '\n'.join(message.get('content', '') for message in body.get('messages', []))
                if 'SUMMARY_ALWAYS_LENGTH' in messages or 'SUMMARY_RECOVERY' in messages:
                    marker = 'SUMMARY_ALWAYS_LENGTH' if 'SUMMARY_ALWAYS_LENGTH' in messages else 'SUMMARY_RECOVERY'
                    summary_attempts[marker] = summary_attempts.get(marker, 0) + 1
                    incomplete = marker == 'SUMMARY_ALWAYS_LENGTH' or summary_attempts[marker] == 1
                    content = 'Never publish this partial summary' if incomplete else 'Aurora launches Friday. Maya checks the report.'
                    self.send_json({'choices': [{'finish_reason': 'length' if incomplete else 'stop', 'message': {'role': 'assistant', 'content': content}}], 'usage': {'completion_tokens': 9}})
                    return
                if 'Slow probe' in messages:
                    time.sleep(2)
                self.send_json({'choices': [{'finish_reason': 'stop', 'message': {'role': 'assistant', 'content': "She doesn't have time today."}}], 'usage': {'completion_tokens': 9}})
                return
            self.send_json({'error': 'Not found'}, 404)

    server = ThreadingHTTPServer(('127.0.0.1', args.port), Handler)
    server.daemon_threads = True
    server.serve_forever()
    """#
}
