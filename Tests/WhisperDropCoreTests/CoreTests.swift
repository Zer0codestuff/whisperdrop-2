import XCTest
@testable import WhisperDropCore

final class CoreTests: XCTestCase {
    func testYouTubeURLsRejectLookalikesAndShellInput() {
        XCTAssertNotNil(MediaInput.youtubeURL("https://www.youtube.com/watch?v=abc&list=xyz"))
        XCTAssertNotNil(MediaInput.youtubeURL("https://youtu.be/abc"))
        for value in ["https://youtube.com.evil.org/watch?v=x", "file:///etc/passwd", "https://youtube.com@evil.org", "$(touch /tmp/oops)", "https://evil.org/?youtube.com"] {
            XCTAssertNil(MediaInput.youtubeURL(value))
        }
    }
    func testWhisperOffsetsAndSubtitleRounding() throws {
        let json = Data(#"{"transcription":[{"offsets":{"from":1234,"to":60000},"text":" Hello."}]}"#.utf8)
        let result = try TranscriptOutput.parseWhisper(json)
        XCTAssertEqual(result[0].start, 1.234)
        XCTAssertEqual(result[0].text, "Hello.")
        XCTAssertEqual(TranscriptOutput.subtitles(result, vtt: false), "1\n00:00:01,234 --> 00:01:00,000\nHello.\n")
        XCTAssertTrue(TranscriptOutput.subtitles(result, vtt: true).hasPrefix("WEBVTT\n\n1\n00:00:01.234"))
    }
    func testJobPersistenceRoundTrip() throws {
        var job = TranscriptionJob(source: URL(fileURLWithPath: "/tmp/lesson.wav"))
        job.status = .completed; job.transcript = "A lesson"
        let copy = try JSONDecoder().decode(TranscriptionJob.self, from: JSONEncoder().encode(job))
        XCTAssertEqual(copy.id, job.id)
        XCTAssertEqual(copy.transcript, job.transcript)
    }
    func testServerVerboseJSONOffsetsAndSpeaker() throws {
        let json = Data(#"{"language":"english","text":" Hi.","segments":[{"id":0,"text":" Hi.","start":0.5,"end":1.25}]}"#.utf8)
        let result = try TranscriptOutput.parseServer(json, offset: 10, speaker: .others)
        XCTAssertEqual(result.language, "english")
        XCTAssertEqual(result.segments.first?.start, 10.5)
        XCTAssertEqual(result.segments.first?.speaker, .others)
        XCTAssertEqual(result.text, "Hi.")
    }
    func testTimeLabelShowsHoursPastOneHour() {
        XCTAssertEqual(TranscriptSegment(id: 0, start: 61.9, end: 62, text: "a").timeLabel, "01:01")
        XCTAssertEqual(TranscriptSegment(id: 0, start: 3599, end: 3600, text: "a").timeLabel, "59:59")
        XCTAssertEqual(TranscriptSegment(id: 0, start: 3661, end: 3662, text: "a").timeLabel, "1:01:01")
    }
    func testWAVHeaderAndLength() {
        let data = WAVEncoder.pcm16([0, 1, -1])
        XCTAssertEqual(data.count, 44 + 6)
        XCTAssertEqual(String(decoding: data.prefix(4), as: UTF8.self), "RIFF")
        XCTAssertEqual(data[34], 16)
    }
}
