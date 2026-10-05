@testable import Shadowing
import XCTest

/// Geometry and labels of the v8 waveform card.
@MainActor
final class WaveformCardTests: XCTestCase {
    private let viewport = TimelineViewport(start: 0, duration: 130, sourceDuration: 130)

    func testBandCoversTheSentenceAndClipsToTheVisibleRange() throws {
        let frame = try XCTUnwrap(
            SentenceBandOverlay.bandFrame(SentenceChunk(start: 48, end: 65), viewport: viewport, width: 1300)
        )
        XCTAssertEqual(frame.minX, 480, accuracy: 0.01)
        XCTAssertEqual(frame.width, 170, accuracy: 0.01)

        let zoomed = TimelineViewport(start: 60, duration: 20, sourceDuration: 130)
        let clipped = try XCTUnwrap(
            SentenceBandOverlay.bandFrame(SentenceChunk(start: 48, end: 65), viewport: zoomed, width: 200)
        )
        XCTAssertEqual(clipped.minX, 0)
        XCTAssertEqual(clipped.width, 50, accuracy: 0.01)
        XCTAssertNil(SentenceBandOverlay.bandFrame(SentenceChunk(start: 1, end: 5), viewport: zoomed, width: 200))
    }

    func testPauseTicksSitInTheMiddleOfEachPause() {
        let chunks = [
            SentenceChunk(start: 0, end: 4), SentenceChunk(start: 5, end: 9), SentenceChunk(start: 9.4, end: 12)
        ]
        XCTAssertEqual(PauseTickMarks.cuts(chunks), [4.5, 9.2])
        XCTAssertEqual(PauseTickMarks.cuts([SentenceChunk(start: 0, end: 4)]), [])
    }

    func testTakeDatesReadTodayYesterdayOrTheDay() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "Asia/Shanghai"))
        let now = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 10, day: 5, hour: 10)))
        let today = try XCTUnwrap(
            calendar.date(from: DateComponents(year: 2026, month: 10, day: 5, hour: 9, minute: 12))
        )
        let yesterday = try XCTUnwrap(calendar.date(byAdding: .hour, value: -13, to: now))
        let older = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 10, day: 3, hour: 8)))
        let english = Locale(identifier: "en_US")
        XCTAssertTrue(TakeDateText.short(today, now: now, calendar: calendar, locale: english).hasPrefix("Today"))
        let yesterdayText = TakeDateText.short(yesterday, now: now, calendar: calendar, locale: english)
        XCTAssertTrue(yesterdayText.hasPrefix("Yesterday"))
        XCTAssertFalse(TakeDateText.short(older, now: now, calendar: calendar, locale: english).contains("Today"))
        XCTAssertTrue(TakeDateText.short(older, now: now, calendar: calendar, locale: english).contains("3"))
    }

    func testCompareModeTitlesCoverEveryMode() {
        XCTAssertEqual(CompareMode.allCases, [.original, .mine, .originalThenMine])
        for mode in CompareMode.allCases {
            _ = CompareModePicker.title(for: mode)
        }
    }
}
