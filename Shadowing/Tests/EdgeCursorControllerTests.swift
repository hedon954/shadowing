import Combine
@testable import Shadowing
import XCTest

/// Designer rule: the resize cursor shows in an edge's 5 px zone and for an edge drag until
/// mouse-up; on mouse-up anywhere, or leaving the zone, it is the arrow at once, also with
/// several lanes next to each other.
@MainActor
final class EdgeCursorControllerTests: XCTestCase {
    private let original = "original"
    private let take = "take-1"

    func testHoveringAnEdgeZoneShowsResizeAndLeavingItShowsTheArrow() {
        let cursor = EdgeCursorController()
        cursor.hover(in: original, overEdge: true)
        XCTAssertTrue(cursor.showsResize(in: original))

        cursor.hover(in: original, overEdge: false) // out of the zone, still in the lane
        XCTAssertFalse(cursor.showsResize)

        cursor.hover(in: original, overEdge: true)
        cursor.hoverEnded(in: original) // out of the lane straight from the zone
        XCTAssertFalse(cursor.showsResize)
    }

    func testADragKeepsResizeOutsideTheZoneUntilMouseUpOutsideTheAreaShowsTheArrow() {
        let cursor = EdgeCursorController()
        cursor.hover(in: original, overEdge: true)
        cursor.dragBegan(in: original)

        cursor.hover(in: original, overEdge: false)
        XCTAssertTrue(cursor.showsResize(in: original), "dragging: still resize")
        cursor.hoverEnded(in: original) // dragged out of the waveform area
        XCTAssertTrue(cursor.showsResize(in: original), "dragging: still resize")

        cursor.dragEnded(in: original, overEdge: false) // released outside
        XCTAssertFalse(cursor.showsResize, "arrow at once")
    }

    func testMouseUpOverTheEdgeKeepsResizeUntilThePointerLeaves() {
        let cursor = EdgeCursorController()
        cursor.dragBegan(in: original)
        cursor.dragEnded(in: original, overEdge: true) // the moved edge is under the pointer
        XCTAssertTrue(cursor.showsResize(in: original))
        cursor.hover(in: original, overEdge: false)
        XCTAssertFalse(cursor.showsResize)
    }

    func testAdjacentLanesInInterleavedOrderEndWithTheArrow() {
        let cursor = EdgeCursorController()
        // Crossing from the original's edge into the take's: the take's enter comes first.
        cursor.hover(in: original, overEdge: true)
        cursor.hover(in: take, overEdge: true)
        cursor.hoverEnded(in: original)
        XCTAssertTrue(cursor.showsResize(in: take))
        XCTAssertFalse(cursor.showsResize(in: original))
        cursor.hover(in: original, overEdge: false) // a late move from the lane just left
        XCTAssertTrue(cursor.showsResize(in: take))
        cursor.hoverEnded(in: take)
        XCTAssertFalse(cursor.showsResize, "ends with the arrow")

        // And back, leaves arriving after enters, then both lanes left in either order.
        cursor.hover(in: take, overEdge: true)
        cursor.hover(in: original, overEdge: true)
        cursor.hoverEnded(in: take)
        cursor.hoverEnded(in: original)
        cursor.hoverEnded(in: take)
        XCTAssertFalse(cursor.showsResize, "ends with the arrow")
    }

    func testDuringADragOnlyTheDraggedLaneShowsResize() {
        let cursor = EdgeCursorController()
        cursor.dragBegan(in: original)
        cursor.hover(in: take, overEdge: true) // dragged across the next lane's edge
        XCTAssertTrue(cursor.showsResize(in: original))
        XCTAssertFalse(cursor.showsResize(in: take))

        cursor.hoverEnded(in: take)
        cursor.dragEnded(in: original, overEdge: false)
        XCTAssertFalse(cursor.showsResize)
        cursor.dragEnded(in: take, overEdge: true) // not dragging there: ignored
        XCTAssertFalse(cursor.showsResize)
    }

    func testALaneGoingAwayMidDragLeavesTheArrow() {
        let cursor = EdgeCursorController()
        cursor.hover(in: take, overEdge: true)
        cursor.dragBegan(in: take)
        cursor.laneDisappeared(take)
        XCTAssertFalse(cursor.showsResize)
    }

    /// Every lane observes the owner, so moving inside the zone must not republish.
    func testMovingInsideTheZonePublishesOnce() {
        let cursor = EdgeCursorController()
        var changes = 0
        let subscription = cursor.objectWillChange.sink { changes += 1 }
        for _ in 0 ..< 5 {
            cursor.hover(in: original, overEdge: true)
        }
        for _ in 0 ..< 5 {
            cursor.hover(in: original, overEdge: false)
        }
        subscription.cancel()
        XCTAssertEqual(changes, 2)
    }
}
