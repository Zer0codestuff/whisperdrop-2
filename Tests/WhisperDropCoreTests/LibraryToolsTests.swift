import Foundation
import XCTest
@testable import WhisperDropCore

final class LibraryToolsTests: XCTestCase {
    private func job(_ title: String = "Lezione", segments: [TranscriptSegment] = []) -> TranscriptionJob {
        var job = TranscriptionJob(source: URL(fileURLWithPath: "/tmp/lezione.m4a"), title: title)
        job.segments = segments
        job.transcript = segments.map(\.text).joined(separator: " ")
        return job
    }

    func testMarkdownHasTitleDetailsTimesAndSpeakers() {
        var note = job("Riunione", segments: [
            TranscriptSegment(id: 0, start: 0, end: 2, text: "Ciao a tutti.", speaker: .you),
            TranscriptSegment(id: 1, start: 65, end: 67, text: "Buongiorno.", speaker: .others)
        ])
        note.modelName = "Parakeet v3"
        note.duration = 187
        XCTAssertEqual(TranscriptOutput.markdown(note), """
        # Riunione

        *Parakeet v3 · 3 min 7 s*

        `00:00` **You** Ciao a tutti.

        `01:05` **Others** Buongiorno.

        """)
    }

    func testJSONKeepsWordTimings() throws {
        let words = [TranscriptWord(start: 0, end: 0.4, text: " Ciao"), TranscriptWord(start: 0.4, end: 0.9, text: " mondo.")]
        let output = try TranscriptOutput.json(job(segments: [TranscriptSegment(id: 0, start: 0, end: 0.9, text: "Ciao mondo.", words: words)]))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any])
        XCTAssertEqual(object["title"] as? String, "Lezione")
        XCTAssertEqual(object["text"] as? String, "Ciao mondo.")
        let segment = try XCTUnwrap((object["segments"] as? [[String: Any]])?.first)
        XCTAssertEqual((segment["words"] as? [[String: Any]])?.count, 2)
    }

    func testDurationLabels() {
        XCTAssertEqual(TranscriptOutput.durationLabel(42), "42 s")
        XCTAssertEqual(TranscriptOutput.durationLabel(120), "2 min")
        XCTAssertEqual(TranscriptOutput.durationLabel(1500), "25 min")
        XCTAssertEqual(TranscriptOutput.durationLabel(3900), "1 h 05 min")
    }

    func testSearchIgnoresCaseAndAccents() {
        let text = "Perché la Città è bella? PERCHE sì."
        XCTAssertEqual(TranscriptSearch.ranges(of: "perche", in: text).map { String(text[$0]) }, ["Perché", "PERCHE"])
        XCTAssertEqual(TranscriptSearch.ranges(of: "citta", in: text).count, 1)
        XCTAssertTrue(TranscriptSearch.ranges(of: "  ", in: text).isEmpty)
        let lesson = job("Analisi 1", segments: [TranscriptSegment(id: 0, start: 0, end: 1, text: "La derivata è un limite.")])
        XCTAssertTrue(TranscriptSearch.matches(lesson, "analisi"))
        XCTAssertTrue(TranscriptSearch.matches(lesson, "LIMITE derivata"))
        XCTAssertFalse(TranscriptSearch.matches(lesson, "integrale"))
        XCTAssertTrue(TranscriptSearch.matches(lesson, ""))
    }

    func testSectionsFollowLibraryOrder() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Rome")!
        let now = calendar.date(from: DateComponents(year: 2026, month: 11, day: 11, hour: 10))!
        func made(daysAgo: Int, _ title: String) -> TranscriptionJob {
            var item = job(title)
            item.created = calendar.date(byAdding: .day, value: -daysAgo, to: now)!
            return item
        }
        let sections = LibrarySections.sections([made(daysAgo: 0, "a"), made(daysAgo: 0, "b"), made(daysAgo: 1, "c"),
                                                 made(daysAgo: 5, "d"), made(daysAgo: 20, "e"), made(daysAgo: 70, "f")],
                                                now: now, calendar: calendar)
        XCTAssertEqual(sections.map(\.title), ["Today", "Yesterday", "Previous 7 days", "Previous 30 days", "September 2026"])
        XCTAssertEqual(sections[0].jobs.map(\.title), ["a", "b"])
    }
}
