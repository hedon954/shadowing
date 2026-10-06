import Foundation
@testable import Shadowing
import XCTest

/// Pausing a take leaves the playhead exactly where it stopped on screen, and the view does
/// not scroll. Until the pause reaches the engine, the take may still report positions in
/// take time (0–1.5 s here); they must never land on the waveform (take at 4–5.5 s).
@MainActor
final class TakePauseTests: XCTestCase {
    private func playingTake() async throws -> (M9Fixture, Take) {
        let fixture = try await M9TestSupport.makeFixtureWithCommittedTake(testCase: self)
        let model = fixture.viewModel
        let take = try XCTUnwrap(model.takes.first)
        model.toggleTakePlayback(take)
        await M9TestSupport.waitUntil { model.isPlaying && model.pendingLocalSeek == nil }
        await fixture.audio.emit(.playheadChanged(1)) // 5.0 s on screen
        await M9TestSupport.waitUntil { abs(model.playhead - (take.region.start + 1)) < 1e-9 }
        return (fixture, take)
    }

    private func assertPauseHoldsThePlayhead(_ pause: (PracticeViewModel, Take) -> Void) async throws {
        let (fixture, take) = try await playingTake()
        let model = fixture.viewModel
        let viewport = model.timelineViewport
        await fixture.audio.holdNextPause()

        pause(model, take)
        await M9TestSupport.waitForCommand(.pause, audio: fixture.audio)
        await fixture.audio.emit(.playheadChanged(1.03)) // the take's last tick, take time
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(model.playhead, take.region.start + 1, accuracy: 1e-9, "not 0:01")
        XCTAssertEqual(model.timelineViewport, viewport, "no scroll")

        await fixture.audio.releaseHeldSeek()
        await M9TestSupport.waitUntil { !model.isPlaying && model.pendingLocalSeek == nil }
        XCTAssertEqual(model.playhead, take.region.start + 1, accuracy: 1e-9)
        XCTAssertEqual(model.timelineViewport, viewport)
    }

    func testPausingWithTheTakesOwnButtonHoldsThePlayhead() async throws {
        try await assertPauseHoldsThePlayhead { model, take in model.toggleTakePlayback(take) }
    }

    func testPausingWithSpaceHoldsThePlayhead() async throws {
        try await assertPauseHoldsThePlayhead { model, _ in model.togglePlayback() }
    }

    func testPausingWithThePauseCommandHoldsThePlayhead() async throws {
        try await assertPauseHoldsThePlayhead { model, _ in model.pause() }
    }
}
