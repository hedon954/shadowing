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

    func testCreatesForwardAndReverseRegionsFromDragCoordinates() throws {
        let forward = try PracticeRegion.fromDrag(
            anchor: 10,
            current: 18,
            sourceDuration: 120
        )
        let reverse = try PracticeRegion.fromDrag(
            anchor: 18,
            current: 10,
            sourceDuration: 120
        )

        XCTAssertEqual(forward.start, 10)
        XCTAssertEqual(forward.end, 18)
        XCTAssertEqual(reverse.start, 10)
        XCTAssertEqual(reverse.end, 18)
    }

    func testDragCreationClampsToSourceAndDurationLimits() throws {
        let beforeSource = try PracticeRegion.fromDrag(
            anchor: 0.2,
            current: -10,
            sourceDuration: 120
        )
        let afterSource = try PracticeRegion.fromDrag(
            anchor: 119.8,
            current: 140,
            sourceDuration: 120
        )
        let maximumForward = try PracticeRegion.fromDrag(
            anchor: 10,
            current: 100,
            sourceDuration: 120
        )
        let maximumReverse = try PracticeRegion.fromDrag(
            anchor: 100,
            current: 10,
            sourceDuration: 120
        )

        XCTAssertEqual(beforeSource.start, 0)
        XCTAssertEqual(beforeSource.end, 0.5)
        XCTAssertEqual(afterSource.start, 119.5)
        XCTAssertEqual(afterSource.end, 120)
        XCTAssertEqual(maximumForward.start, 10)
        XCTAssertEqual(maximumForward.end, 70)
        XCTAssertEqual(maximumReverse.start, 40)
        XCTAssertEqual(maximumReverse.end, 100)
    }

    func testDragCreationExpandsShortSelectionInDragDirection() throws {
        let forward = try PracticeRegion.fromDrag(
            anchor: 10,
            current: 10.1,
            sourceDuration: 120
        )
        let reverse = try PracticeRegion.fromDrag(
            anchor: 10,
            current: 9.9,
            sourceDuration: 120
        )

        XCTAssertEqual(forward.start, 10)
        XCTAssertEqual(forward.end, 10.5)
        XCTAssertEqual(reverse.start, 9.5)
        XCTAssertEqual(reverse.end, 10)
    }

    func testAdjustingStartClampsAtMinimumAndMaximumDuration() throws {
        let id = UUID()
        let region = try PracticeRegion(
            id: id,
            start: 20,
            end: 30,
            sourceDuration: 120
        )

        let minimum = try region.adjustingStart(to: 29.9, sourceDuration: 120)
        let maximum = try region.adjustingStart(to: -100, sourceDuration: 120)

        XCTAssertEqual(minimum.id, id)
        XCTAssertEqual(minimum.start, 29.5)
        XCTAssertEqual(minimum.end, 30)
        XCTAssertEqual(maximum.start, 0)
        XCTAssertEqual(maximum.end, 30)
    }

    func testAdjustingEndClampsAtMinimumMaximumAndSourceEnd() throws {
        let region = try PracticeRegion(start: 20, end: 30, sourceDuration: 120)
        let minimum = try region.adjustingEnd(to: 20.1, sourceDuration: 120)
        let maximum = try region.adjustingEnd(to: 100, sourceDuration: 120)
        let sourceEndRegion = try PracticeRegion(start: 110, end: 115, sourceDuration: 120)
        let sourceEnd = try sourceEndRegion.adjustingEnd(to: 140, sourceDuration: 120)

        XCTAssertEqual(minimum.start, 20)
        XCTAssertEqual(minimum.end, 20.5)
        XCTAssertEqual(maximum.end, 80)
        XCTAssertEqual(sourceEnd.end, 120)
    }

    func testClampingPreservesDurationAndMovesRegionInsideShorterSource() throws {
        let region = try PracticeRegion(start: 90, end: 100, sourceDuration: 120)

        let clamped = try region.clamped(to: 95)

        XCTAssertEqual(clamped.start, 85)
        XCTAssertEqual(clamped.end, 95)
        XCTAssertEqual(clamped.duration, 10)
    }

    func testDragCreationRejectsInvalidCoordinatesAndTooShortSource() {
        XCTAssertThrowsError(
            try PracticeRegion.fromDrag(
                anchor: .infinity,
                current: 1,
                sourceDuration: 120
            )
        )
        XCTAssertThrowsError(
            try PracticeRegion.fromDrag(
                anchor: 0,
                current: 0.2,
                sourceDuration: 0.49
            )
        )
    }
}
