import Foundation
@testable import Shadowing
import XCTest

/// The original → take swap must never look like the main track ended (no flash to 02:09).
@MainActor
final class CompareSwapTests: XCTestCase {
    private func hasPlayTakeSegment(_ audio: PracticeAudioClientSpy, after count: Int) async -> Bool {
        let commands = await audio.commands
        return commands.suffix(from: min(count, commands.count)).contains {
            if case .playTakeSegment = $0 {
                return true
            }
            return false
        }
    }

    private func hasSeek(to position: TimeInterval, _ audio: PracticeAudioClientSpy, after count: Int) async -> Bool {
        let commands = await audio.commands
        return commands.suffix(from: min(count, commands.count)).contains {
            if case let .seek(value) = $0 {
                return abs(value - position) < 1e-9
            }
            return false
        }
    }

    func testEndOfItemEventsDuringSwapKeepPlayheadPlayStateAndComparison() async throws {
        let fixture = try await M9TestSupport.makeFixtureWithCommittedTake(testCase: self)
        let model = fixture.viewModel
        let take = try XCTUnwrap(model.takes.first)
        let duration = fixture.project.duration
        model.seek(to: 5.5)
        await M9TestSupport.waitForCommand(.seek(5.5), audio: fixture.audio)
        model.setCompareMode(.originalThenMine)

        model.compare()
        await M9TestSupport.waitUntil { model.isPlaying }
        let pinned = try XCTUnwrap(model.comparison)
        XCTAssertEqual(model.playhead, 5.5, accuracy: 1e-9, "Compare does not move the playhead")

        // The real order at the swap: the item end is reported as the track's end, then an end signal.
        let commandsBeforeSwap = await fixture.audio.commands.count
        model.receive(.playheadChanged(duration))
        model.receive(.playbackFinished)
        XCTAssertEqual(model.playhead, 5.5, accuracy: 1e-9, "no flash to the end of the track")
        XCTAssertTrue(model.isPlaying, "the play button keeps showing that Compare plays")
        XCTAssertEqual(model.comparison, pinned, "a stray track end does not touch Compare")
        XCTAssertNotEqual(model.project.playhead, duration)

        // The engine's segment end moves Compare on to the take.
        model.receive(.segmentFinished)
        XCTAssertEqual(model.playhead, 5.5, accuracy: 1e-9)
        XCTAssertTrue(model.isPlaying, "the gap between original and take still counts as playing")
        XCTAssertNotNil(model.comparison)
        await M9TestSupport.waitUntilAsync {
            await self.hasPlayTakeSegment(fixture.audio, after: commandsBeforeSwap)
        }
        XCTAssertEqual(model.playingTakeID, take.id)

        // Take-local time and the take item's end never feed the main playhead.
        model.receive(.playheadChanged(take.duration))
        model.receive(.playheadChanged(duration))
        model.receive(.playbackFinished)
        XCTAssertEqual(model.playhead, 5.5, accuracy: 1e-9)
        XCTAssertTrue(model.isPlaying)
        XCTAssertEqual(model.playingTakeID, take.id)
        XCTAssertNotNil(model.comparison)

        // Compare still finishes and restores normally.
        let commandsBeforeFinish = await fixture.audio.commands.count
        model.receive(.segmentFinished)
        XCTAssertNil(model.comparison)
        XCTAssertFalse(model.isPlaying)
        XCTAssertNil(model.playingTakeID)
        XCTAssertEqual(model.playhead, 5.5, accuracy: 1e-9)
        await M9TestSupport.waitUntilAsync {
            await self.hasSeek(to: 5.5, fixture.audio, after: commandsBeforeFinish)
        }
    }

    func testSegmentEndWithLateTrackEndPlayheadDoesNotMoveFrozenPlayhead() async throws {
        let fixture = try await M9TestSupport.makeFixtureWithCommittedTake(testCase: self)
        let model = fixture.viewModel
        model.seek(to: 6)
        await M9TestSupport.waitForCommand(.seek(6), audio: fixture.audio)
        model.compare()
        await M9TestSupport.waitUntil { model.isPlaying }

        await fixture.audio.emit(.playheadChanged(fixture.project.duration))
        await fixture.audio.emit(.segmentFinished)
        await M9TestSupport.waitUntilAsync {
            await self.hasPlayTakeSegment(fixture.audio, after: 0)
        }
        XCTAssertEqual(model.playhead, 6, accuracy: 1e-9)
        XCTAssertTrue(model.isPlaying)
        XCTAssertNotNil(model.comparison)
    }

    func testReplayedSentenceEndStopsInPlaceInsteadOfJumpingToTrackEnd() async throws {
        let fixture = try await M9TestSupport.makeFixtureWithCommittedTake(testCase: self)
        let model = fixture.viewModel
        model.replayCurrentSentence()
        await M9TestSupport.waitUntil { model.isPlaying }

        model.receive(.playheadChanged(fixture.region.end))
        model.receive(.segmentFinished)
        XCTAssertFalse(model.isPlaying)
        XCTAssertEqual(model.playhead, fixture.region.end, accuracy: 1e-9)
    }
}
