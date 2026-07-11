import Foundation
@testable import Shadowing
import XCTest

final class TakeDisplayOrderingTests: XCTestCase {
    func testNextTopDisplayOrderStartsAtZero() {
        XCTAssertEqual(TakeDisplayOrdering.nextTopDisplayOrder(existing: []), 0)
    }

    func testNextTopDisplayOrderInsertsAboveExisting() throws {
        let region = try PracticeRegion(start: 0, end: 1, sourceDuration: 10)
        let first = try Take(
            projectID: UUID(),
            region: region,
            sequence: 1,
            displayOrder: 0,
            relativeAudioPath: "a.caf",
            duration: 1,
            createdAt: Date(timeIntervalSince1970: 1)
        )
        let second = try Take(
            projectID: first.projectID,
            region: region,
            sequence: 2,
            displayOrder: -1,
            relativeAudioPath: "b.caf",
            duration: 1,
            createdAt: Date(timeIntervalSince1970: 2)
        )
        XCTAssertEqual(TakeDisplayOrdering.nextTopDisplayOrder(existing: [first]), -1)
        XCTAssertEqual(
            TakeDisplayOrdering.nextTopDisplayOrder(existing: [second, first]),
            -2
        )
    }

    func testMovingOntoTargetReindexesContiguously() throws {
        let region = try PracticeRegion(start: 0, end: 1, sourceDuration: 10)
        let projectID = UUID()
        let top = try Take(
            projectID: projectID,
            region: region,
            sequence: 2,
            displayOrder: 0,
            relativeAudioPath: "top.caf",
            duration: 1,
            createdAt: Date(timeIntervalSince1970: 2)
        )
        let bottom = try Take(
            projectID: projectID,
            region: region,
            sequence: 1,
            displayOrder: 1,
            relativeAudioPath: "bottom.caf",
            duration: 1,
            createdAt: Date(timeIntervalSince1970: 1)
        )

        let moved = try TakeDisplayOrdering.moving(
            [top, bottom],
            draggedID: bottom.id,
            onto: top.id
        )
        XCTAssertEqual(moved?.map(\.id), [bottom.id, top.id])
        XCTAssertEqual(moved?.map(\.displayOrder), [0, 1])
        XCTAssertEqual(moved?.map(\.sequence), [1, 2])
    }
}
