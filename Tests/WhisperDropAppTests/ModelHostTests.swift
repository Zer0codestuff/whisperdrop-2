import Darwin
import XCTest
import WhisperDropCore
@testable import WhisperDrop

@MainActor
final class ModelHostTests: XCTestCase {
    override func setUp() async throws {
        executionTimeAllowance = 240
    }

    func testAudioContextRoundsUpToAMultipleOf64() {
        // 0 s -> 160 frames, which is not a multiple of 64, so the next step is 192.
        XCTAssertEqual(ModelHost.audioContext(duration: 0), 192)
        // 1 s -> 210 frames, ceil to 256.
        XCTAssertEqual(ModelHost.audioContext(duration: 1), 256)
        // 5 s -> 410 frames, ceil to 448. Above the measured-good window of 384.
        XCTAssertEqual(ModelHost.audioContext(duration: 5), 448)
        // 25 s -> 1410 frames, ceil to 1472, still under the 1500 encoder cap.
        XCTAssertEqual(ModelHost.audioContext(duration: 25), 1472)
        // Past the model's n_audio_ctx the formula caps at 1500.
        XCTAssertEqual(ModelHost.audioContext(duration: 40), 1500)
        XCTAssertEqual(ModelHost.audioContext(duration: 5) % 64, 0)
        XCTAssertEqual(ModelHost.audioContext(duration: 25) % 64, 0)
    }

    func testMissingModelSurfacesTheClosureError() async throws {
        struct Missing: LocalizedError {
            var errorDescription: String? { "Download the Turbo model before transcribing." }
        }
        let pidFile = FileManager.default.temporaryDirectory.appendingPathComponent("WhisperDrop-host-test-\(UUID().uuidString).pid")
        let host = ModelHost(tool: { _ in URL(fileURLWithPath: "/usr/bin/true") }, modelFile: { _ in throw Missing() }, processFile: pidFile)
        defer { host.shutdown() }
        let model = TranscriptionModel.catalog.first { $0.id == "turbo" }!
        do {
            try await host.ensureReady(model)
            XCTFail("Expected the missing model to throw")
        } catch {
            XCTAssertEqual(error.localizedDescription, "Download the Turbo model before transcribing.")
        }
        XCTAssertEqual(host.state, .unloaded)

        host.prewarm(model)
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline {
            if case .failed = host.state { break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        guard case .failed(let message) = host.state else {
            XCTFail("Prewarm should publish the failure, got \(host.state)")
            return
        }
        XCTAssertEqual(message, "Download the Turbo model before transcribing.")
    }

    func testResidentServerTranscribesAndHonorsIdlePolicy() async throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let binary = root.appendingPathComponent(".runtime/bin/whisper-server")
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: binary.path), "whisper-server is not built")
        let tiny = URL(fileURLWithPath: "/private/tmp/whisperdrop2-verification/library/Models/ggml-tiny-q5_1.bin")
        let turbo = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/WhisperDrop 2/Models/ggml-large-v3-turbo-q5_0.bin")
        let modelURL: URL
        if FileManager.default.isReadableFile(atPath: tiny.path) {
            modelURL = tiny
        } else if FileManager.default.isReadableFile(atPath: turbo.path) {
            modelURL = turbo
        } else {
            throw XCTSkip("No Tiny or Turbo model is on disk")
        }
        let wavURL = URL(fileURLWithPath: "/private/tmp/grok-orchestrator-gabrielemonni/runs/20260929-161838-wispr-features/research/s5.wav")
        try XCTSkipUnless(FileManager.default.isReadableFile(atPath: wavURL.path), "s5.wav is missing")
        let model = try XCTUnwrap(TranscriptionModel.catalog.first { $0.filename == modelURL.lastPathComponent })
        let samples = try decodePCM16WAV(Data(contentsOf: wavURL))
        XCTAssertEqual(samples.count, 80_000)

        let pidFile = FileManager.default.temporaryDirectory.appendingPathComponent("WhisperDrop-host-test-\(UUID().uuidString).pid")
        let host = ModelHost(
            tool: { name in
                let url = binary.deletingLastPathComponent().appendingPathComponent(name)
                guard FileManager.default.isExecutableFile(atPath: url.path) else {
                    throw AppFailure("\(name) is missing from this app. Rebuild with scripts/build-app.sh or install a complete WhisperDrop 2 build.")
                }
                return url
            },
            modelFile: { requested in
                guard requested.id == model.id else {
                    throw AppFailure("Download the \(requested.name) model before transcribing.")
                }
                return modelURL
            }, processFile: pidFile
        )
        defer { host.shutdown() }

        host.keepReady = true
        host.residency = .tenMinutes
        let ready = Task { try await host.ensureReady(model) }
        let loadDeadline = Date().addingTimeInterval(90)
        var sawLoadingAfterThreeSeconds = false
        let loadStarted = Date()
        while Date() < loadDeadline {
            if host.state == .loading, Date().timeIntervalSince(loadStarted) >= 3 {
                sawLoadingAfterThreeSeconds = true
            }
            if host.state == .ready { break }
            if case .failed = host.state { break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        try await ready.value
        XCTAssertEqual(host.state, .ready)
        XCTAssertEqual(host.loadedModel, model.id)
        XCTAssertTrue(host.stateTrace.contains(.loading))
        if Date().timeIntervalSince(loadStarted) >= 3 {
            XCTAssertTrue(sawLoadingAfterThreeSeconds)
        }
        let pid = try XCTUnwrap(host.serverProcessIdentifier)
        XCTAssertTrue(isAlive(pid))
        XCTAssertTrue(FileManager.default.fileExists(atPath: pidFile.path))

        let transcript = try await host.transcribe(samples, model: model, language: "en", shortClip: true)
        XCTAssertFalse(transcript.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        XCTAssertTrue(host.stateTrace.contains(.busy))
        XCTAssertEqual(host.state, .ready)
        XCTAssertTrue(isAlive(pid))

        host.residency = .afterUse
        try await Task.sleep(nanoseconds: 250_000_000)
        XCTAssertEqual(host.state, .ready)
        XCTAssertTrue(isAlive(pid), "Keep ready holds the model past an immediate idle policy")

        let lease = host.acquireLease()
        host.keepReady = false
        try await Task.sleep(nanoseconds: 250_000_000)
        XCTAssertEqual(host.state, .ready)
        XCTAssertTrue(isAlive(pid), "A lease holds the model past an immediate idle policy")

        host.releaseLease(lease)
        XCTAssertEqual(host.state, .unloaded)
        XCTAssertFalse(isAlive(pid))
        XCTAssertNil(host.loadedModel)

        let again = try await host.transcribe(samples, model: model, language: "en", shortClip: true)
        XCTAssertFalse(again.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        XCTAssertEqual(host.state, .unloaded)
        XCTAssertNil(host.serverProcessIdentifier)

        host.keepReady = true
        host.residency = .tenMinutes
        try await host.ensureReady(model)
        let restarted = try XCTUnwrap(host.serverProcessIdentifier)
        XCTAssertTrue(isAlive(restarted))
        host.shutdown()
        XCTAssertEqual(host.state, .unloaded)
        XCTAssertFalse(isAlive(restarted))
        XCTAssertFalse(FileManager.default.fileExists(atPath: pidFile.path))
        XCTAssertNil(host.serverProcessIdentifier)
    }
}

private func isAlive(_ pid: pid_t) -> Bool {
    pid > 0 && kill(pid, 0) == 0
}

private func decodePCM16WAV(_ data: Data) throws -> [Float] {
    guard data.count > 12, String(decoding: data.prefix(4), as: UTF8.self) == "RIFF",
          String(decoding: data.dropFirst(8).prefix(4), as: UTF8.self) == "WAVE" else {
        throw AppFailure("The sample is not a WAV file.")
    }
    var offset = 12
    var format: UInt16 = 0
    var channels: UInt16 = 0
    var sampleRate: UInt32 = 0
    var bits: UInt16 = 0
    var payload: Data?
    while offset + 8 <= data.count {
        let identifier = String(decoding: data[offset..<offset + 4], as: UTF8.self)
        let size = Int(readUInt32(data, offset + 4))
        let start = offset + 8
        guard size >= 0, start + size <= data.count else { break }
        if identifier == "fmt ", size >= 16 {
            format = readUInt16(data, start)
            channels = readUInt16(data, start + 2)
            sampleRate = readUInt32(data, start + 4)
            bits = readUInt16(data, start + 14)
        } else if identifier == "data" {
            payload = data.subdata(in: start..<(start + size))
        }
        offset = start + size + (size % 2)
    }
    guard format == 1, channels == 1, sampleRate == 16_000, bits == 16, let payload else {
        throw AppFailure("The sample is not 16 kHz mono 16-bit PCM.")
    }
    var samples: [Float] = []
    samples.reserveCapacity(payload.count / 2)
    var index = 0
    while index + 1 < payload.count {
        let bits = UInt16(payload[index]) | (UInt16(payload[index + 1]) << 8)
        samples.append(Float(Int16(bitPattern: bits)) / 32768)
        index += 2
    }
    return samples
}

private func readUInt16(_ data: Data, _ offset: Int) -> UInt16 {
    UInt16(data[offset]) | (UInt16(data[offset + 1]) << 8)
}

private func readUInt32(_ data: Data, _ offset: Int) -> UInt32 {
    UInt32(data[offset]) | (UInt32(data[offset + 1]) << 8) | (UInt32(data[offset + 2]) << 16) | (UInt32(data[offset + 3]) << 24)
}
