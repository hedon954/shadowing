@testable import Shadowing
import XCTest

/// v9 window title: cleaned name, subtitle "2:10 · 3 takes" (or only the length before any take).
final class PracticeTitleTextTests: XCTestCase {
    func testShowsOnlyTheLengthBeforeTheFirstTake() {
        XCTAssertEqual(PracticeTitleText.summary(duration: 132, takeCount: 0), "2:12")
    }

    func testShowsLengthThenTakeCount() {
        let summary = PracticeTitleText.summary(duration: 130, takeCount: 3)
        XCTAssertTrue(summary.hasPrefix("2:10 · 3"), summary)
    }

    func testSubtitleShowsTheSummaryOrWhatRecordingIsDoing() {
        XCTAssertEqual(PracticeTitleText.subtitle(for: .takes(count: 0, lastPracticed: nil), duration: 130), "2:10")
        let takes = PracticeTitleText.subtitle(for: .takes(count: 3, lastPracticed: nil), duration: 130)
        XCTAssertTrue(takes.hasPrefix("2:10 · 3"), takes)
        XCTAssertEqual(PracticeTitleText.subtitle(for: .recording(takeNumber: 4), duration: 130), "● Recording Take 4")
        XCTAssertEqual(
            PracticeTitleText.subtitle(for: .countingDown(takeNumber: 4, remainingSeconds: 2), duration: 130),
            "Recording starts in 2"
        )
    }

    func testRecordingSubtitleIsLocalized() throws {
        let path = try XCTUnwrap(Bundle(for: AppNavigationModel.self).path(forResource: "zh-Hans", ofType: "lproj"))
        let zh = try XCTUnwrap(Bundle(path: path))
        let template = zh.localizedString(forKey: "Recording Take %lld", value: nil, table: nil)
        XCTAssertEqual(String(format: template, 4), "正在录第 4 遍")
    }
}
