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
            return saved?.viewportStart == 40
        }
        let saved = try await fixture.projects.project(id: fixture.projectID)
        XCTAssertEqual(saved?.viewportDuration, 8)
        XCTAssertEqual(saved?.playhead, 62)
        XCTAssertEqual(saved?.savedTimelineViewport, model.timelineViewport)
    }

    /// Playback ticks no longer save the project. Switching to another project while playing
    /// closes this practice, which must save the position and zoom at that moment so switching
    /// back resumes there, even though the delayed save never ran.
    func testSwitchingAwayWhilePlayingSavesThePositionAndZoomForSwitchingBack() async throws {
        let fixture = try await M7TestSupport.makeHydrateFixture(
            testCase: self, duration: 129, region: 27 ... 30, playhead: 62, visibleRange: 55 ... 70
        )
        let model = fixture.viewModel
        model.playheadPersistDelay = .seconds(60)
        model.start()
        await M7TestSupport.waitUntil { model.revealToken > 0 }
        model.togglePlayback()
        await M7TestSupport.waitUntil { model.isPlaying }
        for tick in 1 ... 30 {
            await fixture.audio.emit(.playheadChanged(62 + Double(tick) * 0.1))
        }
        await M7TestSupport.waitUntil { abs(model.playhead - 65) < 1e-9 }
        model.setTimelineViewport(TimelineViewport(start: 60, duration: 10, sourceDuration: 129))
        let beforeSwitch = try await fixture.projects.project(id: fixture.projectID)
        XCTAssertEqual(beforeSwitch?.playhead, 62, "ticks alone do not save")

        await model.close() // what switching to another project runs first

        let savedOrNil = try await fixture.projects.project(id: fixture.projectID)
        let saved = try XCTUnwrap(savedOrNil)
        XCTAssertEqual(saved.playhead, 65, accuracy: 1e-9)
        XCTAssertEqual(saved.savedTimelineViewport, TimelineViewport(start: 60, duration: 10, sourceDuration: 129))

        let reopened = PracticeViewModel(
            prepared: PreparedPractice(
                project: saved,
                waveform: WaveformPresentation(peaks: [0.2, 0.5], warning: nil)
            ),
            audioClient: PracticeAudioClientSpy(),
            projects: fixture.projects,
            sessionPreparer: M7SessionPreparer()
        )
        reopened.start()
        await M7TestSupport.waitUntil { reopened.revealToken > 0 }
        XCTAssertEqual(reopened.playhead, 65, accuracy: 1e-9)
        XCTAssertEqual(reopened.timelineViewport, TimelineViewport(start: 60, duration: 10, sourceDuration: 129))
        await reopened.close()
    }

    // MARK: - Loop (no take): restored exactly as left, never turned on, never moves the playhead

    /// Drag-selected 0:36–0:44, then clicked at 1:20 (which turned the loop off).
    func testLoopLeftOffWithThePlayheadOutsideTheSelectionComesBackThere() async throws {
        let fixture = try await M7TestSupport.makeHydrateFixture(
            testCase: self, duration: 129, region: 36 ... 44, playhead: 80, visibleRange: 70 ... 90,
            selectsTake: false, loopEnabled: false
        )
        let model = fixture.viewModel
        model.start()
        await M7TestSupport.waitForCommand(.seek(80), audio: fixture.audio)

        XCTAssertEqual(model.playhead, 80, accuracy: 1e-9, "not moved to the selection start")
        XCTAssertFalse(model.loopEnabled, "opening never turns the loop on")
        XCTAssertEqual(model.region, fixture.region, "the selection stays")
        XCTAssertEqual(model.timelineViewport, TimelineViewport(start: 70, duration: 20, sourceDuration: 129))
        let commands = await fixture.audio.commands
        XCTAssertFalse(commands.contains {
            if case .setLoop = $0 {
                true
            } else {
                false
            }
        })
    }

    func testLoopLeftOffInsideTheSelectionStaysOff() async throws {
        let fixture = try await M7TestSupport.makeHydrateFixture(
            testCase: self, duration: 129, region: 36 ... 44, playhead: 40, selectsTake: false, loopEnabled: false
        )
        let model = fixture.viewModel
        model.start()
        await M7TestSupport.waitForCommand(.seek(40), audio: fixture.audio)
        XCTAssertFalse(model.loopEnabled)
        XCTAssertEqual(model.playhead, 40, accuracy: 1e-9)
    }

    func testLoopLeftOnComesBackOnAtTheSavedPlayhead() async throws {
        let fixture = try await M7TestSupport.makeHydrateFixture(
            testCase: self, duration: 129, region: 36 ... 44, playhead: 41, selectsTake: false, loopEnabled: true
        )
        let model = fixture.viewModel
        model.start()
        await M7TestSupport.waitForCommand(.seek(41), audio: fixture.audio)
        XCTAssertTrue(model.loopEnabled)
        XCTAssertEqual(model.playhead, 41, accuracy: 1e-9)
        let commands = await fixture.audio.commands
        XCTAssertEqual(Array(commands.suffix(2)), [.setLoop(fixture.region), .seek(41)])
    }

    /// Only old data can say "loop on" with the playhead outside: the playhead wins.
    func testLoopSavedOnButPlayheadOutsideKeepsThePlayheadAndLeavesLoopOff() async throws {
        let fixture = try await M7TestSupport.makeHydrateFixture(
            testCase: self, duration: 129, region: 36 ... 44, playhead: 80, selectsTake: false, loopEnabled: true
        )
        let model = fixture.viewModel
        model.start()
        await M7TestSupport.waitForCommand(.seek(80), audio: fixture.audio)
        XCTAssertEqual(model.playhead, 80, accuracy: 1e-9)
        XCTAssertFalse(model.loopEnabled)
    }

    /// The loop state is saved with the project, so the next open sees it.
    func testLoopStateIsSavedOnClose() async throws {
        let fixture = try await M7TestSupport.makeHydrateFixture(
            testCase: self, duration: 129, region: 36 ... 44, playhead: 40, selectsTake: false, loopEnabled: true
        )
        let model = fixture.viewModel
        model.start()
        await M7TestSupport.waitForCommand(.seek(40), audio: fixture.audio)
        model.setLoopEnabled(false)
        await model.close()
        let saved = try await fixture.projects.project(id: fixture.projectID)
        XCTAssertEqual(saved?.loopEnabled, false)
    }
}
