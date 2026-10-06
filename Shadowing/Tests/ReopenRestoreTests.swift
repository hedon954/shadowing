import Foundation
@testable import Shadowing
import XCTest

/// Reopening a project puts back where the user was: the saved playhead and the zoomed
/// waveform's visible range. A selected take stays selected but no longer moves the playhead
/// to its start, and a saved zoom is never replaced by the full waveform.
@MainActor
final class ReopenRestoreTests: XCTestCase {
    /// Take on 0:27–0:30, closed at 1:02 while looking at 0:55–1:10.
    func testSelectedTakeKeepsTheSavedPlayheadAndZoom() async throws {
        let fixture = try await M7TestSupport.makeHydrateFixture(
            testCase: self, duration: 129, region: 27 ... 30, playhead: 62, visibleRange: 55 ... 70
        )
        let model = fixture.viewModel
        model.start()
        await M7TestSupport.waitUntil { model.revealToken > 0 }

        XCTAssertEqual(model.playhead, 62, accuracy: 1e-9)
        XCTAssertEqual(model.playheadClock.position, 62, accuracy: 1e-9)
        XCTAssertEqual(model.activeTake?.id, fixture.take.id, "the take stays selected")
        XCTAssertEqual(model.project.currentRegion, fixture.region, "the selection is unchanged")
        XCTAssertEqual(model.timelineViewport, TimelineViewport(start: 55, duration: 15, sourceDuration: 129))
        await M7TestSupport.waitForCommand(.seek(62), audio: fixture.audio)
    }

    /// Older projects have no saved range: show the take's region and the playhead together.
    func testWithoutASavedRangeTheTakeAndThePlayheadAreBothVisible() async throws {
        let fixture = try await M7TestSupport.makeHydrateFixture(
            testCase: self, duration: 129, region: 27 ... 30, playhead: 62
        )
        let model = fixture.viewModel
        model.start()
        await M7TestSupport.waitUntil { model.revealToken > 0 }

        XCTAssertEqual(model.playhead, 62, accuracy: 1e-9)
        XCTAssertTrue(model.timelineViewport.contains(62), "\(model.timelineViewport)")
        XCTAssertLessThanOrEqual(model.timelineViewport.start, 27)
        XCTAssertGreaterThanOrEqual(model.timelineViewport.end, 30)
        XCTAssertLessThan(model.timelineViewport.duration, 129, "not the full waveform")
    }

    func testWithoutATakeTheSavedZoomIsRestoredNotTheFullWaveform() async throws {
        let fixture = try await M7TestSupport.makeHydrateFixture(
            testCase: self, duration: 129, region: 27 ... 30, playhead: 62, visibleRange: 58 ... 64,
            selectsTake: false
        )
        let model = fixture.viewModel
        model.start()
        await M7TestSupport.waitUntil { model.revealToken > 0 }

        XCTAssertNil(model.activeTake)
        XCTAssertEqual(model.playhead, 62, accuracy: 1e-9)
        XCTAssertEqual(model.timelineViewport, TimelineViewport(start: 58, duration: 6, sourceDuration: 129))
    }

    /// Zooming after the restore is saved (debounced) together with the playhead.
    func testZoomAndPanAreSavedForTheNextOpen() async throws {
        let fixture = try await M7TestSupport.makeHydrateFixture(
            testCase: self, duration: 129, region: 27 ... 30, playhead: 62, visibleRange: 55 ... 70
        )
        let model = fixture.viewModel
        model.playheadPersistDelay = .milliseconds(1)
        model.start()
        await M7TestSupport.waitUntil { model.revealToken > 0 }

        model.setTimelineViewport(TimelineViewport(start: 40, duration: 8, sourceDuration: 129))
        await M7TestSupport.waitUntil {
            let saved = try? await fixture.projects.project(id: fixture.projectID)
            return saved?.timelineVisibleStart == 40
        }
        let saved = try await fixture.projects.project(id: fixture.projectID)
        XCTAssertEqual(saved?.timelineVisibleDuration, 8)
        XCTAssertEqual(saved?.playhead, 62)
        XCTAssertEqual(saved?.savedTimelineViewport, model.timelineViewport)
    }
}
