import Foundation
@testable import Shadowing
import XCTest

final class TakeOverwritePlanTests: XCTestCase {
    func testFullCoverFromSameStartNeedsNoSplice() {
        let plan = TakeOverwritePlan.planning(
            previousStart: 10,
            previousDuration: 5,
            newStart: 10,
            newDuration: 8
        )
        XCTAssertEqual(plan.resultStart, 10, accuracy: 0.0001)
        XCTAssertEqual(plan.resultDuration, 8, accuracy: 0.0001)
        XCTAssertEqual(plan.headDuration, 0, accuracy: 0.0001)
        XCTAssertEqual(plan.tailDuration, 0, accuracy: 0.0001)
        XCTAssertEqual(plan.silenceDuration, 0, accuracy: 0.0001)
        XCTAssertFalse(plan.needsSplice)
    }

    func testMidOverwriteKeepsHeadAndTail() {
        let plan = TakeOverwritePlan.planning(
            previousStart: 10,
            previousDuration: 10,
            newStart: 13,
            newDuration: 3
        )
        XCTAssertEqual(plan.resultStart, 10, accuracy: 0.0001)
        XCTAssertEqual(plan.resultDuration, 10, accuracy: 0.0001)
        XCTAssertEqual(plan.headDuration, 3, accuracy: 0.0001)
        XCTAssertEqual(plan.insertedDuration, 3, accuracy: 0.0001)
        XCTAssertEqual(plan.tailDuration, 4, accuracy: 0.0001)
        XCTAssertEqual(plan.previousTailLocalStart, 6, accuracy: 0.0001)
        XCTAssertEqual(plan.silenceDuration, 0, accuracy: 0.0001)
        XCTAssertTrue(plan.needsSplice)
    }

    func testOverwriteExtendingPastEndKeepsHeadOnly() {
        let plan = TakeOverwritePlan.planning(
            previousStart: 10,
            previousDuration: 5,
            newStart: 12,
            newDuration: 6
        )
        XCTAssertEqual(plan.resultStart, 10, accuracy: 0.0001)
        XCTAssertEqual(plan.resultDuration, 8, accuracy: 0.0001)
        XCTAssertEqual(plan.headDuration, 2, accuracy: 0.0001)
        XCTAssertEqual(plan.tailDuration, 0, accuracy: 0.0001)
        XCTAssertEqual(plan.silenceDuration, 0, accuracy: 0.0001)
        XCTAssertTrue(plan.needsSplice)
    }

    func testNonOverlappingAfterInsertsSilenceGap() {
        let plan = TakeOverwritePlan.planning(
            previousStart: 10,
            previousDuration: 2,
            newStart: 20,
            newDuration: 2
        )
        XCTAssertEqual(plan.resultStart, 10, accuracy: 0.0001)
        XCTAssertEqual(plan.resultDuration, 12, accuracy: 0.0001)
        XCTAssertEqual(plan.headDuration, 2, accuracy: 0.0001)
        XCTAssertEqual(plan.silenceDuration, 8, accuracy: 0.0001)
        XCTAssertEqual(plan.insertedDuration, 2, accuracy: 0.0001)
        XCTAssertEqual(plan.tailDuration, 0, accuracy: 0.0001)
        XCTAssertEqual(plan.segments.count, 3)
        XCTAssertTrue(plan.needsSplice)
    }

    func testNonOverlappingBeforeInsertsSilenceGap() {
        let plan = TakeOverwritePlan.planning(
            previousStart: 20,
            previousDuration: 2,
            newStart: 10,
            newDuration: 2
        )
        XCTAssertEqual(plan.resultStart, 10, accuracy: 0.0001)
        XCTAssertEqual(plan.resultDuration, 12, accuracy: 0.0001)
        XCTAssertEqual(plan.insertedDuration, 2, accuracy: 0.0001)
        XCTAssertEqual(plan.silenceDuration, 8, accuracy: 0.0001)
        XCTAssertEqual(plan.tailDuration, 2, accuracy: 0.0001)
        XCTAssertEqual(plan.previousTailLocalStart, 0, accuracy: 0.0001)
        XCTAssertEqual(plan.segments.count, 3)
        XCTAssertTrue(plan.needsSplice)
    }

    func testAdjacentRecordingHasNoSilence() {
        let plan = TakeOverwritePlan.planning(
            previousStart: 10,
            previousDuration: 2,
            newStart: 12,
            newDuration: 2
        )
        XCTAssertEqual(plan.resultDuration, 4, accuracy: 0.0001)
        XCTAssertEqual(plan.silenceDuration, 0, accuracy: 0.0001)
        XCTAssertEqual(plan.headDuration, 2, accuracy: 0.0001)
        XCTAssertEqual(plan.insertedDuration, 2, accuracy: 0.0001)
        XCTAssertTrue(plan.needsSplice)
    }
}
