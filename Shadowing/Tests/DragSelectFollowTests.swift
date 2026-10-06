import Combine
import Foundation
@testable import Shadowing
import XCTest

/// While the user drags on the zoomed waveform its visible range stays still; seeks and
/// reveals during the drag wait and pan at most once on release.
@MainActor
final class DragSelectFollowTests: XCTestCase {
    private func zoomedViewport() -> TimelineViewport {
        TimelineViewport(start: 20, duration: 3, sourceDuration: 30)
    }

    func testSeeksAndRevealsDuringDragKeepVisibleRangeStill() async throws {
        let fixture = try await M9TestSupport.makeFixture(testCase: self)
        let model = fixture.viewModel
        model.timelineViewport = zoomedViewport()
        let viewportChanges = ViewportChangeCounter(model)
        let tokenBefore = model.jumpReveal.token

        model.setTimelineGestureActive(true)
        model.seekTimeline(10)
        model.seek(to: 2)
        model.revealPlayhead()
        try model.revealPlayhead(focus: PracticeRegion(start: 0, end: 12, sourceDuration: 30))
        model.followPlayheadInTimeline(at: model.playhead)

        XCTAssertEqual(model.timelineViewport, zoomedViewport(), "no pan and no zoom while dragging")
        XCTAssertEqual(viewportChanges.count, 0)
        XCTAssertEqual(model.jumpReveal.token, tokenBefore + 4, "the transcript still follows each jump")
    }

    func testDragEndPansOnceWhenPlayheadIsOffScreen() async throws {
        let fixture = try await M9TestSupport.makeFixture(testCase: self)
        let model = fixture.viewModel
        model.timelineViewport = zoomedViewport()
        let viewportChanges = ViewportChangeCounter(model)

        model.setTimelineGestureActive(true)
        model.seekTimeline(10)
        model.seekTimeline(11)
        model.seek(to: 12)
        XCTAssertEqual(viewportChanges.count, 0)

        model.setTimelineGestureActive(false)
        XCTAssertEqual(viewportChanges.count, 1, "exactly one pan on release")
        XCTAssertTrue(model.timelineViewport.contains(12))
        XCTAssertEqual(model.timelineViewport.duration, 3, accuracy: 1e-9, "release keeps the zoom")

        model.setTimelineGestureActive(false)
        XCTAssertEqual(viewportChanges.count, 1, "a second release does not pan again")
    }

    func testDragEndDoesNotPanWhenTargetIsAlreadyVisible() async throws {
        let fixture = try await M9TestSupport.makeFixture(testCase: self)
        let model = fixture.viewModel
        model.timelineViewport = zoomedViewport()
        let viewportChanges = ViewportChangeCounter(model)

        model.setTimelineGestureActive(true)
        model.seekTimeline(5) // off-screen mid-drag ...
        model.seekTimeline(21) // ... but visible by the time the user lets go
        model.setTimelineGestureActive(false)

        XCTAssertEqual(viewportChanges.count, 0)
        XCTAssertEqual(model.timelineViewport, zoomedViewport())
    }

    func testDragEndWithoutAnyJumpLeavesVisibleRangeAlone() async throws {
        let fixture = try await M9TestSupport.makeFixture(testCase: self)
        let model = fixture.viewModel
        model.timelineViewport = zoomedViewport()
        XCTAssertFalse(model.timelineViewport.contains(model.playhead))
        let viewportChanges = ViewportChangeCounter(model)

        model.setTimelineGestureActive(true)
        model.setTimelineGestureActive(false)

        XCTAssertEqual(viewportChanges.count, 0, "a plain drag never yanks the view to the playhead")
    }

    func testPlaybackFollowDuringDragWaitsForRelease() async throws {
        let fixture = try await M9TestSupport.makeFixture(testCase: self)
        let model = fixture.viewModel
        model.timelineViewport = zoomedViewport()
        let viewportChanges = ViewportChangeCounter(model)

        model.setTimelineGestureActive(true)
        model.followPlayheadInTimeline(at: model.playhead)
        XCTAssertEqual(viewportChanges.count, 0)

        model.setTimelineGestureActive(false)
        XCTAssertEqual(viewportChanges.count, 1)
        XCTAssertTrue(model.timelineViewport.contains(model.playhead))
        XCTAssertEqual(model.timelineViewport.duration, 3, accuracy: 1e-9)
    }

    func testTakeClickDuringDragRevealsTakeOnceOnRelease() async throws {
        let fixture = try await M9TestSupport.makeFixtureWithCommittedTake(testCase: self)
        let model = fixture.viewModel
        let take = try XCTUnwrap(model.takes.first)
        model.timelineViewport = zoomedViewport()
        let viewportChanges = ViewportChangeCounter(model)

        model.setTimelineGestureActive(true)
        model.selectTake(take)
        model.focusTimelineForTakePlayback(take)
        XCTAssertEqual(model.timelineViewport, zoomedViewport())

        model.setTimelineGestureActive(false)
        XCTAssertEqual(viewportChanges.count, 1)
        XCTAssertLessThanOrEqual(model.timelineViewport.start, take.region.start)
        XCTAssertGreaterThanOrEqual(model.timelineViewport.end, take.region.end)
        if take.region.duration <= 3 {
            XCTAssertEqual(model.timelineViewport.duration, 3, accuracy: 1e-9, "the take fits, so the zoom stays")
        }
    }

    func testFocusWiderThanWindowZoomsOutOnRelease() async throws {
        let fixture = try await M9TestSupport.makeFixture(testCase: self)
        let model = fixture.viewModel
        model.timelineViewport = zoomedViewport()
        let wide = try PracticeRegion(start: 2, end: 12, sourceDuration: 30)

        model.setTimelineGestureActive(true)
        model.seekTimeline(2)
        model.revealPlayhead(focus: wide)
        model.setTimelineGestureActive(false)

        XCTAssertLessThanOrEqual(model.timelineViewport.start, wide.start)
        XCTAssertGreaterThanOrEqual(model.timelineViewport.end, wide.end)
    }

    func testJumpsAfterReleaseRevealImmediatelyAgain() async throws {
        let fixture = try await M9TestSupport.makeFixtureWithCommittedTake(testCase: self)
        let model = fixture.viewModel
        let take = try XCTUnwrap(model.takes.first)
        model.setTimelineGestureActive(true)
        model.setTimelineGestureActive(false)

        model.timelineViewport = zoomedViewport()
        model.seek(to: 10) // transcript sentence click
        XCTAssertTrue(model.timelineViewport.contains(10))

        model.timelineViewport = zoomedViewport()
        model.selectTake(take) // take click
        XCTAssertLessThanOrEqual(model.timelineViewport.start, take.region.start)
        XCTAssertGreaterThanOrEqual(model.timelineViewport.end, take.region.end)

        model.timelineViewport = zoomedViewport()
        model.seekTimeline(2) // waveform click (no drag)
        XCTAssertTrue(model.timelineViewport.contains(2))
    }
}

/// Counts every assignment to the waveform's visible range after it is created.
private final class ViewportChangeCounter {
    private(set) var count = 0
    private var subscription: AnyCancellable?

    @MainActor
    init(_ model: PracticeViewModel) {
        subscription = model.$timelineViewport
            .dropFirst()
            .sink { [weak self] _ in self?.count += 1 }
    }
}
