import Foundation
@testable import Shadowing
import SwiftUI
import XCTest

/// Active jumps reveal the playhead in the zoomed waveform and the transcript; only the user's
/// own transcript scrolling pauses auto-follow, for 3 s.
@MainActor
final class JumpRevealTests: XCTestCase {
    /// Ten 3 s sentences over the 30 s fixture source.
    private let cues = (0 ..< 10).map { index in
        SubtitleCue(start: Double(index) * 3, end: Double(index) * 3 + 3, text: "Sentence \(index).")
    }

    private func zoomedAwayViewport() -> TimelineViewport {
        TimelineViewport(start: 20, duration: 3, sourceDuration: 30)
    }

    func testSeekAndScrubBumpRevealSetSentenceAndScrollZoomedWaveform() async throws {
        let fixture = try await M9TestSupport.makeFixture(testCase: self)
        let model = fixture.viewModel
        model.subtitles.display = .timed(SubtitleTranscript(cues: cues))
        model.timelineViewport = zoomedAwayViewport()
        let before = model.jumpReveal.token

        model.seekTimeline(10) // drag / click on the waveform
        XCTAssertEqual(model.jumpReveal.token, before + 1)
        XCTAssertEqual(model.currentCueIndex, 3)
        XCTAssertTrue(model.timelineViewport.contains(10), "zoomed waveform scrolls to the playhead")
        XCTAssertEqual(model.timelineViewport.duration, 3, accuracy: 1e-9, "reveal keeps the zoom")

        model.seek(to: 25.5) // clicking a transcript sentence calls seek(to:)
        XCTAssertEqual(model.jumpReveal.token, before + 2)
        XCTAssertEqual(model.currentCueIndex, 8)
        XCTAssertTrue(model.timelineViewport.contains(25.5))
    }

    func testSentenceClickRevealsWhilePausedEvenRightAfterUserScroll() async throws {
        let fixture = try await M9TestSupport.makeFixture(testCase: self)
        let model = fixture.viewModel
        model.subtitles.display = .timed(SubtitleTranscript(cues: cues))
        XCTAssertFalse(model.isPlaying)
        let now = Date()
        model.noteTranscriptUserScroll(at: now)
        XCTAssertFalse(model.transcriptAutoFollows(at: now))
        let before = model.jumpReveal.token

        model.seek(to: cues[6].start)
        XCTAssertEqual(model.jumpReveal.token, before + 1)
        XCTAssertEqual(model.currentCueIndex, 6)
        XCTAssertTrue(model.transcriptAutoFollows(at: now), "an active jump ends the user-scroll pause")
    }

    func testClickingTakeScrollsZoomedWaveformToTakeAndReveals() async throws {
        let fixture = try await M9TestSupport.makeFixtureWithCommittedTake(testCase: self)
        let model = fixture.viewModel
        let take = try XCTUnwrap(model.takes.first)
        model.subtitles.display = .timed(SubtitleTranscript(cues: cues))
        model.timelineViewport = zoomedAwayViewport()
        let before = model.jumpReveal.token

        model.selectTake(take)
        XCTAssertEqual(model.jumpReveal.token, before + 1)
        XCTAssertEqual(model.playhead, take.region.start, accuracy: 1e-9)
        XCTAssertEqual(model.currentCueIndex, SubtitleTimeline.cueIndex(at: take.region.start, in: cues))
        XCTAssertLessThanOrEqual(model.timelineViewport.start, take.region.start)
        XCTAssertGreaterThanOrEqual(model.timelineViewport.end, take.region.end)
        XCTAssertTrue(model.timelineViewport.contains(model.playhead))
    }

    func testUserScrollPausesAutoFollowForThreeSeconds() async throws {
        let fixture = try await M9TestSupport.makeFixture(testCase: self)
        let model = fixture.viewModel
        let start = Date(timeIntervalSince1970: 1000)
        XCTAssertTrue(model.transcriptAutoFollows(at: start))

        model.noteTranscriptUserScroll(at: start)
        XCTAssertFalse(model.transcriptAutoFollows(at: start.addingTimeInterval(2.9)))
        XCTAssertTrue(model.transcriptAutoFollows(at: start.addingTimeInterval(3)))
    }

    func testProgrammaticRevealNeverStartsTheUserScrollPause() async throws {
        let fixture = try await M9TestSupport.makeFixture(testCase: self)
        let model = fixture.viewModel
        let before = model.jumpReveal.token

        model.revealPlayhead()
        XCTAssertEqual(model.jumpReveal.token, before + 1)
        XCTAssertNil(model.jumpReveal.userScrolledAt)
        XCTAssertTrue(model.transcriptAutoFollows(at: Date()))

        // scrollTo animates; only phases the user drives count as a user scroll.
        XCTAssertFalse(ScrollPhase.isUserScroll(from: .idle, to: .animating))
        XCTAssertFalse(ScrollPhase.isUserScroll(from: .animating, to: .idle))
        XCTAssertTrue(ScrollPhase.isUserScroll(from: .idle, to: .interacting))
        XCTAssertTrue(ScrollPhase.isUserScroll(from: .interacting, to: .decelerating))
        XCTAssertTrue(ScrollPhase.isUserScroll(from: .decelerating, to: .idle))
    }

    func testOpeningProjectSetsCurrentSentenceAndRevealsImmediately() async throws {
        let fixture = try await M9TestSupport.makeFixture(
            testCase: self,
            selectRegion: false,
            restoredPlayhead: 13
        )
        let model = fixture.viewModel
        await M9TestSupport.waitUntil { model.jumpReveal.token > 0 }
        model.subtitles.display = .timed(SubtitleTranscript(cues: cues))
        XCTAssertEqual(model.playhead, 13, accuracy: 1e-9)
        XCTAssertEqual(model.currentCueIndex, 4)
        XCTAssertTrue(model.timelineViewport.contains(13))
        XCTAssertTrue(model.transcriptAutoFollows(at: Date()))
        await M9TestSupport.waitForCommand(.seek(13), audio: fixture.audio)
    }
}
