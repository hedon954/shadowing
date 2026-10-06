@testable import Shadowing
import XCTest

/// Designer rule: an edge is grabbed within 5 px on either side, in the full and the zoomed
/// view alike; a press there moving less than 3 px is a plain click.
final class WaveformSelectionEdgesTests: XCTestCase {
    private let region = try! PracticeRegion(start: 12, end: 14, sourceDuration: 60) // swiftlint:disable:this force_try
    /// 600 px for 60 s: 10 px a second; the edges sit at 120 and 140 px.
    private let full = WaveformSelectionEdges(
        viewport: TimelineViewport(start: 0, duration: 60, sourceDuration: 60),
        width: 600
    )
    /// 600 px for 6 s from 10 s: 100 px a second; the edges sit at 200 and 400 px.
    private let zoomed = WaveformSelectionEdges(
        viewport: TimelineViewport(start: 10, duration: 6, sourceDuration: 60),
        width: 600
    )

    func testTheGrabZoneIsFivePointsOnEachSideInBothViews() {
        for (edges, startX, endX) in [(full, 120.0, 140.0), (zoomed, 200.0, 400.0)] {
            XCTAssertEqual(edges.edge(at: startX - 5, of: region), .start)
            XCTAssertEqual(edges.edge(at: startX + 5, of: region), .start)
            XCTAssertNil(edges.edge(at: startX - 5.5, of: region))
            XCTAssertNil(edges.edge(at: startX + 5.5, of: region))
            XCTAssertEqual(edges.edge(at: endX - 5, of: region), .end)
            XCTAssertEqual(edges.edge(at: endX + 5, of: region), .end)
            XCTAssertNil(edges.edge(at: endX + 5.5, of: region))
            XCTAssertNil(edges.edge(at: (startX + endX) / 2, of: region), "inside: a plain click")
        }
        XCTAssertNil(full.edge(at: 120, of: nil))
    }

    func testOverlappingZonesPickTheNearerEdge() throws {
        let narrow = try PracticeRegion(start: 12, end: 12.5, sourceDuration: 60) // 120 and 125 px
        XCTAssertEqual(full.edge(at: 122, of: narrow), .start)
        XCTAssertEqual(full.edge(at: 123, of: narrow), .end)
    }

    func testAPressOnAnEdgeMovingLessThanThreePointsIsAPlainClick() {
        XCTAssertNil(zoomed.pressKind(startX: 203, distance: 0, region: region))
        XCTAssertNil(zoomed.pressKind(startX: 203, distance: 2.9, region: region))
        XCTAssertEqual(zoomed.pressKind(startX: 203, distance: 3, region: region), .resize(.start))
        XCTAssertEqual(full.pressKind(startX: 144, distance: 3, region: region), .resize(.end))
    }

    func testAPressOutsideTheZoneIsAClickUntilItDragsANewSelection() {
        XCTAssertNil(zoomed.pressKind(startX: 206, distance: 3, region: region), "no resize")
        XCTAssertEqual(zoomed.pressKind(startX: 206, distance: 4, region: region), .select)
        XCTAssertNil(full.pressKind(startX: 300, distance: 0, region: nil))
    }

    /// Grabbed 3 px beside the edge, it moves by the drag and does not jump to the pointer.
    func testADraggedEdgeMovesByTheDrag() {
        XCTAssertEqual(zoomed.draggedEdgeTime(.end, of: region, from: 403, to: 453), 14.5, accuracy: 1e-9)
        XCTAssertEqual(full.draggedEdgeTime(.start, of: region, from: 117, to: 107), 11, accuracy: 1e-9)
    }
}
