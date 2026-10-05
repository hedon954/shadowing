@testable import Shadowing
import XCTest

/// v6 title bar: cleaned name, then "2:10 · 3 takes" (or only the length before any take).
final class PracticeTitleTextTests: XCTestCase {
    func testShowsOnlyTheLengthBeforeTheFirstTake() {
        XCTAssertEqual(PracticeTitleText.summary(duration: 132, takeCount: 0), "2:12")
    }

    func testShowsLengthThenTakeCount() {
        let summary = PracticeTitleText.summary(duration: 130, takeCount: 3)
        XCTAssertTrue(summary.hasPrefix("2:10 · 3"), summary)
    }

    func testRecordingSubtitleIsLocalized() throws {
        let path = try XCTUnwrap(Bundle(for: AppNavigationModel.self).path(forResource: "zh-Hans", ofType: "lproj"))
        let zh = try XCTUnwrap(Bundle(path: path))
        let template = zh.localizedString(forKey: "Recording Take %lld", value: nil, table: nil)
        XCTAssertEqual(String(format: template, 4), "正在录第 4 遍")
    }
}
