@testable import Shadowing
import XCTest

final class TakePlaybackTimingTests: XCTestCase {
    func testSelectionFromDragClampsInsideTakeBounds() throws {
        let take = try PracticeRegion.takeAlignment(
            start: 10,
            end: 20,
            sourceDuration: 60
        )

        let selected = try XCTUnwrap(
            TakePlaybackTiming.selectionFromDrag(
                anchor: 8,
                current: 25,
                takeRegion: take,
                sourceDuration: 60
            )
        )

        XCTAssertEqual(selected.start, 10, accuracy: 0.001)
        XCTAssertEqual(selected.end, 20, accuracy: 0.001)
    }

    func testLocalLoopMapsTakeSelectionIntoTakeTimeline() throws {
        let take = try PracticeRegion.takeAlignment(
            start: 4,
            end: 10,
            sourceDuration: 30
        )
        let selection = try PracticeRegion(start: 5, end: 8, sourceDuration: 30)

        let local = try XCTUnwrap(
            TakePlaybackTiming.localLoopRegion(
                selection: selection,
                takeRegion: take
            )
        )

        XCTAssertEqual(local.start, 1, accuracy: 0.001)
        XCTAssertEqual(local.end, 4, accuracy: 0.001)
    }

    func testLocalLoopReturnsNilWhenOverlapBelowMinimum() throws {
        let take = try PracticeRegion.takeAlignment(
            start: 4.3,
            end: 10,
            sourceDuration: 30
        )
        let selection = try PracticeRegion(start: 4, end: 4.6, sourceDuration: 30)

        XCTAssertNil(
            TakePlaybackTiming.localLoopRegion(
                selection: selection,
                takeRegion: take
            )
        )
    }

    func testLocalLoopReturnsNilWhenRegionsDoNotOverlap() throws {
        let take = try PracticeRegion.takeAlignment(
            start: 10,
            end: 14,
            sourceDuration: 30
        )
        let selection = try PracticeRegion(start: 1, end: 3, sourceDuration: 30)

        XCTAssertNil(
            TakePlaybackTiming.localLoopRegion(
                selection: selection,
                takeRegion: take
            )
        )
    }
}
