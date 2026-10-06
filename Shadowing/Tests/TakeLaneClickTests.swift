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

    // MARK: - Take loop + click outside it: the loop stays, the playhead goes where clicked

    private func waitForPlayTake(_ fixture: M9Fixture, _ take: Take, from local: TimeInterval) async {
        let selection = fixture.viewModel.takeLoopSelections[take.id]
        let loop = selection.flatMap { TakePlaybackTiming.localLoopRegion(selection: $0, takeRegion: take.region) }
        await M9TestSupport.waitUntilAsync {
            await fixture.audio.commands.contains {
                if case let .playTake(id, from, sent) = $0 {
                    // Regions carry their own id: compare the span.
                    return id == take.id && abs(from - local) < 1e-9
                        && sent?.start == loop?.start && sent?.end == loop?.end && sent != nil
                }
                return false
            }
        }
    }

    /// Take 4–7 s (1.5 s of audio) playing with its loop on 0.5–1.0 s of the take.
    private func playingTakeWithLoop(_ fixture: M9Fixture) async throws -> Take {
        let model = fixture.viewModel
        let take = try XCTUnwrap(model.takes.first)
        await playingTake(fixture, take)
        let selection = try PracticeRegion(
            start: take.region.start + 0.5,
            end: take.region.start + 1,
            sourceDuration: model.project.duration
        )
        model.selectTakeLoopRegion(take, selection)
        await waitForPlayTake(fixture, take, from: 0.5) // selecting a loop starts it
        return take
    }

    private func assertClickOutsideTheTakeLoopKeepsItAndPlaysFrom(_ local: TimeInterval) async throws {
        let fixture = try await M9TestSupport.makeFixtureWithCommittedTake(testCase: self)
        let model = fixture.viewModel
        let take = try await playingTakeWithLoop(fixture)
        let selection = model.takeLoopSelections[take.id]

        model.seekTakeLane(take, to: take.region.start + local)
        // From the click, with the loop: the engine plays into it (before) or straight on (after).
        await waitForPlayTake(fixture, take, from: local)
        XCTAssertEqual(model.takeLoopSelections[take.id], selection, "the take's loop stays")
        XCTAssertEqual(model.playhead, take.region.start + local, accuracy: 1e-9, "not moved to the loop start")
        XCTAssertTrue(model.isPlaying)
        XCTAssertEqual(model.playingTakeID, take.id)
    }

    func testClickBeforeThePlayingTakesLoopKeepsTheLoop() async throws {
        try await assertClickOutsideTheTakeLoopKeepsItAndPlaysFrom(0.2)
    }

    func testClickAfterThePlayingTakesLoopKeepsTheLoop() async throws {
        try await assertClickOutsideTheTakeLoopKeepsItAndPlaysFrom(1.2)
    }

    func testClickOutsideAPausedTakesLoopKeepsTheLoopAndStaysPaused() async throws {
        let fixture = try await M9TestSupport.makeFixtureWithCommittedTake(testCase: self)
        let model = fixture.viewModel
        let take = try XCTUnwrap(model.takes.first)
        let selection = try PracticeRegion(
            start: take.region.start + 0.5,
            end: take.region.start + 1,
            sourceDuration: model.project.duration
        )
        model.selectTakeLoopRegion(take, selection)
        XCTAssertFalse(model.isPlaying)
        let before = await fixture.audio.commands.count
        let spot = take.region.start + 1.2

        model.seekTakeLane(take, to: spot)
        await M9TestSupport.waitForCommand(.seek(spot), audio: fixture.audio)

        XCTAssertEqual(model.takeLoopSelections[take.id], selection, "the take's loop stays")
        XCTAssertEqual(model.playhead, spot, accuracy: 1e-9)
        XCTAssertFalse(model.isPlaying)
        let after = await commands(after: before, fixture)
        XCTAssertFalse(after.contains(where: startsSound), "nothing starts: \(after)")
    }

    // MARK: - Seek gate: positions from before the click never pull the playhead back

    func testStaleTakePositionsDuringTheClickAreIgnored() async throws {
        let fixture = try await M9TestSupport.makeFixtureWithCommittedTake(testCase: self)
        let model = fixture.viewModel
        let take = try XCTUnwrap(model.takes.first)
        await playingTake(fixture, take)
        await fixture.audio.holdNextPlayTake()
        let spot = take.region.start + 1.0

        model.seekTakeLane(take, to: spot)
        await M9TestSupport.waitForCommand(.playTake(takeID: take.id, from: 1.0, loop: nil), audio: fixture.audio)
        await fixture.audio.emit(.playheadChanged(0.1)) // the take, before it restarted
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(model.playhead, spot, accuracy: 1e-9, "a stale position is ignored")

        await fixture.audio.releaseHeldSeek()
        await M9TestSupport.waitUntil { model.pendingLocalSeek == nil }
        await fixture.audio.emit(.playheadChanged(1.1))
        await M9TestSupport.waitUntil { abs(model.playhead - (take.region.start + 1.1)) < 1e-9 }
    }

    func testAFailedTakeRestartReleasesTheGate() async throws {
        let fixture = try await M9TestSupport.makeFixtureWithCommittedTake(testCase: self)
        let model = fixture.viewModel
        let take = try XCTUnwrap(model.takes.first)
        await playingTake(fixture, take)
        await fixture.audio.failNextPlayTake(with: PracticeAudioEngineError.sourceNotLoaded)

        model.seekTakeLane(take, to: take.region.start + 1.0)
        await M9TestSupport.waitForCommand(.playTake(takeID: take.id, from: 1.0, loop: nil), audio: fixture.audio)
        await M9TestSupport.waitUntil { model.pendingLocalSeek == nil }
    }
}
