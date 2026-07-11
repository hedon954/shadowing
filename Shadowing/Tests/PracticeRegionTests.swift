@testable import Shadowing
import XCTest

final class PracticeRegionTests: XCTestCase {
    func testAcceptsBoundaryDurations() throws {
        let minimum = try PracticeRegion(start: 1, end: 1.5, sourceDuration: 120)
        let maximum = try PracticeRegion(start: 1, end: 61, sourceDuration: 120)

        XCTAssertEqual(minimum.duration, 0.5)
        XCTAssertEqual(maximum.duration, 60)
    }

    func testRejectsRegionOutsideSource() {
        XCTAssertThrowsError(
            try PracticeRegion(start: -1, end: 2, sourceDuration: 120)
        )
        XCTAssertThrowsError(
            try PracticeRegion(start: 100, end: 121, sourceDuration: 120)
        )
    }

    func testRejectsRegionOutsideDurationLimits() {
        XCTAssertThrowsError(
            try PracticeRegion(start: 1, end: 1.4, sourceDuration: 120)
        )
        XCTAssertThrowsError(
            try PracticeRegion(start: 1, end: 62, sourceDuration: 120)
        )
    }
}
