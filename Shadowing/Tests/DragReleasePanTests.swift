import Combine
import Foundation
@testable import Shadowing
import XCTest

/// Releasing a drag-selection while playing: the waveform pans at most once, straight to where
/// playback continues (the selection and its start), never first toward the playhead that is
/// about to jump. Engine positions from before the jump are not followed.
@MainActor
final class DragReleasePanTests: XCTestCase {
    private func zoomedViewport() -> TimelineViewport {
        TimelineViewport(start: 20, duration: 3, sourceDuration: 30)
    }

    /// Playing at 10 while the user looks at 20–23 and drags out 21–22 there.
    private func playingOffScreen() async throws -> M9Fixture {
        let fixture = try await M9TestSupport.makeFixture(testCase: self, selectRegion: false)
        let model = fixture.viewModel
        await M9TestSupport.waitUntil { model.revealToken > 0 }
        model.togglePlayback()
        await M9TestSupport.waitUntil { model.isPlaying }
        await fixture.audio.emit(.playheadChanged(10))
        await M9TestSupport.waitUntil { abs(model.playhead - 10) < 1e-9 }
        model.setTimelineViewport(zoomedViewport())
        return fixture
    }

    func testReleaseOnScreenSelectionWhilePlayingNeverPansTowardOldPlayhead() async throws {
        let fixture = try await playingOffScreen()
        let model = fixture.viewModel
        let viewportChanges = ViewportCounter(model)
        let selection = try PracticeRegion(start: 21, end: 22, sourceDuration: 30)

        model.setTimelineGestureActive(true)
        await fixture.audio.emit(.playheadChanged(10.1)) // playback keeps reporting during the drag
        await M9TestSupport.waitUntil { abs(model.playhead - 10.1) < 1e-9 }
        model.selectRegion(selection) // release: the selection commits, then the drag ends
        model.setTimelineGestureActive(false)

        XCTAssertEqual(model.playhead, 21, accuracy: 1e-9, "playback continues at the selection start")
        XCTAssertEqual(viewportChanges.count, 0, "the selection and its start are already visible")

        await fixture.audio.emit(.playheadChanged(10.2)) // reported before the engine seeked
        await M9TestSupport.waitForCommand(.seek(21), audio: fixture.audio)
        await fixture.audio.emit(.playheadChanged(21.05))
        await M9TestSupport.waitUntil { abs(model.playhead - 21.05) < 1e-9 }
        XCTAssertEqual(viewportChanges.count, 0, "no pan toward the old playhead, none back")
        XCTAssertEqual(model.timelineViewport, zoomedViewport())
    }

    func testReleaseWithOffScreenTargetPansExactlyOnceStraightThere() async throws {
        let fixture = try await playingOffScreen()
        let model = fixture.viewModel
        let viewportChanges = ViewportCounter(model)
        let selection = try PracticeRegion(start: 5, end: 7, sourceDuration: 30)

        model.setTimelineGestureActive(true)
        model.selectRegion(selection) // committed off-screen (e.g. by a shortcut mid-drag)
        XCTAssertEqual(viewportChanges.count, 0, "still while dragging")
        model.setTimelineGestureActive(false)

        XCTAssertEqual(viewportChanges.count, 1, "one pan on release")
        XCTAssertLessThanOrEqual(model.timelineViewport.start, selection.start)
        XCTAssertGreaterThanOrEqual(model.timelineViewport.end, selection.end, "the whole selection is visible")
        XCTAssertEqual(model.timelineViewport.duration, 3, accuracy: 1e-9, "zoom kept")

        await fixture.audio.emit(.playheadChanged(10.3)) // stale, from before the seek
        await M9TestSupport.waitForCommand(.seek(5), audio: fixture.audio)
        await fixture.audio.emit(.playheadChanged(5.05))
        await M9TestSupport.waitUntil { abs(model.playhead - 5.05) < 1e-9 }
        XCTAssertEqual(viewportChanges.count, 1, "the seek that follows causes no further pan")
    }

    func testPositionsResumeAfterTheSeekIsApplied() async throws {
        let fixture = try await playingOffScreen()
        let model = fixture.viewModel
        model.seek(to: 21)
        await fixture.audio.emit(.playheadChanged(10.4))
        await M9TestSupport.waitForCommand(.seek(21), audio: fixture.audio)
        await M9TestSupport.waitUntil { model.pendingLocalSeek == nil }
        XCTAssertEqual(model.playhead, 21, accuracy: 1e-9, "the stale position was dropped")
        await fixture.audio.emit(.playheadChanged(21.5))
        await M9TestSupport.waitUntil { abs(model.playhead - 21.5) < 1e-9 }
    }
}

/// Counts assignments to the waveform's visible range after it is created.
private final class ViewportCounter {
    private(set) var count = 0
    private var subscription: AnyCancellable?

    @MainActor
    init(_ model: PracticeViewModel) {
        subscription = model.$timelineViewport
            .dropFirst()
            .sink { [weak self] _ in self?.count += 1 }
    }
}
