import Foundation
@testable import Shadowing
import XCTest

final class ComparisonPlaybackSchedulerTests: XCTestCase {
    func testImmediateSchedulerCompletesWithoutSleeping() async throws {
        let scheduler = ImmediateComparisonPlaybackScheduler()
        try await scheduler.waitForABGap()
    }

    func testContinuousSchedulerUsesConfiguredGap() async throws {
        let scheduler = ContinuousComparisonPlaybackScheduler(gap: .milliseconds(1))
        let started = ContinuousClock.now
        try await scheduler.waitForABGap()
        let elapsed = ContinuousClock.now - started
        XCTAssertGreaterThanOrEqual(elapsed, .milliseconds(1))
    }
}
