import Foundation
@testable import Shadowing
import XCTest

/// Designer rule for a single waveform click while a take is playing: the playing take's own
/// lane keeps playing from the click spot; any other lane stops the take and moves the
/// playhead there, paused (a click never starts a different sound); Compare keeps its rules.
@MainActor
final class TakeLaneClickTests: XCTestCase {
    private func playingTake(_ fixture: M9Fixture, _ take: Take) async {
        let model = fixture.viewModel
        model.toggleTakePlayback(take)
        await M9TestSupport.waitUntil { model.isPlaying && model.playingTakeID == take.id }
        await M9TestSupport.waitForCommand(.playTake(takeID: take.id, from: 0, loop: nil), audio: fixture.audio)
    }

    private func commands(after count: Int, _ fixture: M9Fixture) async -> [PracticeAudioCommand] {
        await Array(fixture.audio.commands.dropFirst(count))
    }

    private func startsSound(_ command: PracticeAudioCommand) -> Bool {
        switch command {
        case .playOriginal, .playTake, .playTakeSegment, .playOriginalSegment:
            true
        default:
            false
        }
    }

    func testClickOnThePlayingTakesLaneKeepsItPlayingFromTheClick() async throws {
        let fixture = try await M9TestSupport.makeFixtureWithCommittedTake(testCase: self)
        let model = fixture.viewModel
        let take = try XCTUnwrap(model.takes.first)
        await playingTake(fixture, take)
        let before = await fixture.audio.commands.count

        model.seekTakeLane(take, to: take.region.start + 0.5)
        await M9TestSupport.waitForCommand(.playTake(takeID: take.id, from: 0.5, loop: nil), audio: fixture.audio)

        XCTAssertTrue(model.isPlaying)
        XCTAssertEqual(model.playingTakeID, take.id)
        XCTAssertEqual(model.playhead, take.region.start + 0.5, accuracy: 1e-9)
        let after = await commands(after: before, fixture)
        XCTAssertFalse(after.contains(.pause), "the take is never paused: \(after)")
    }

    func testClickOnTheOriginalStopsTheTakeMovesThePlayheadAndStaysPaused() async throws {
        let fixture = try await M9TestSupport.makeFixtureWithCommittedTake(testCase: self)
        let model = fixture.viewModel
        let take = try XCTUnwrap(model.takes.first)
        await playingTake(fixture, take)
        let before = await fixture.audio.commands.count

        // What `OriginalWaveformSection` runs on a click.
        model.clearTakeSelection()
        model.seekTimeline(21)
        await M9TestSupport.waitForCommand(.seek(21), audio: fixture.audio)
        await M9TestSupport.waitUntil { !model.isPlaying }

        XCTAssertNil(model.playingTakeID)
        XCTAssertEqual(model.playhead, 21, accuracy: 1e-9)
        let after = await commands(after: before, fixture)
        XCTAssertTrue(after.contains(.pause), "the take stops: \(after)")
        XCTAssertFalse(after.contains(where: startsSound), "nothing starts playing: \(after)")
    }

    func testClickOnAnotherTakesLaneStopsThePlayingTakeAndStaysPaused() async throws {
        let fixture = try await M9TestSupport.makeFixtureWithCommittedTake(testCase: self)
        let model = fixture.viewModel
        let playing = try XCTUnwrap(model.takes.first)
        let other = try await M9TestSupport.commitAdditionalTake(
            fixture: fixture,
            region: fixture.region,
            sequence: 2,
            createdAt: Date(timeIntervalSince1970: 2_000_000_000)
        )
        await model.refreshTakes()
        XCTAssertEqual(model.takes.count, 2)
        await playingTake(fixture, playing)
        let before = await fixture.audio.commands.count
        let spot = other.region.start + 0.7

        model.seekTakeLane(other, to: spot)
        await M9TestSupport.waitForCommand(.seek(spot), audio: fixture.audio)
        await M9TestSupport.waitUntil { !model.isPlaying }

        XCTAssertNil(model.playingTakeID)
        XCTAssertEqual(model.playhead, spot, accuracy: 1e-9)
        let after = await commands(after: before, fixture)
        XCTAssertTrue(after.contains(.pause), "the playing take stops: \(after)")
        XCTAssertFalse(after.contains(where: startsSound), "the clicked take does not start: \(after)")
    }

    func testClickDuringCompareKeepsTheCompareRules() async throws {
        let fixture = try await M9TestSupport.makeFixtureWithCommittedTake(testCase: self)
        let model = fixture.viewModel
        let take = try XCTUnwrap(model.takes.first)
        model.setCompareMode(.mine)
        model.compare()
        await M9TestSupport.waitUntil { model.playingTakeID == take.id }
        XCTAssertNotNil(model.comparison)
        let before = await fixture.audio.commands.count
        let spot = take.region.start + 0.5

        // Same outcome as any waveform click during Compare: Compare ends, playhead moves, paused.
        model.seekTakeLane(take, to: spot)
        await M9TestSupport.waitForCommand(.seek(spot), audio: fixture.audio)

        XCTAssertNil(model.comparison)
        XCTAssertNil(model.playingTakeID)
        XCTAssertFalse(model.isPlaying)
        XCTAssertEqual(model.playhead, spot, accuracy: 1e-9)
        let after = await commands(after: before, fixture)
        XCTAssertFalse(after.contains(where: startsSound), "a click never restarts the take: \(after)")
    }
}
