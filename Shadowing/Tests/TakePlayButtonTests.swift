import Foundation
@testable import Shadowing
import XCTest

/// Designer rule: a take's play button starts from that take's own playhead (a click on its
/// lane, or where its playback got to). Only a take with no playhead yet, or whose last
/// playback reached the end, starts from its loop start (or 0). Then the loop rule applies:
/// before the loop it plays into it and loops; after it, straight on to the end.
/// Fixture take: waveform 4…7 s, 3 s long (finished from 2.5 s on, see
/// `takeEndFinishThreshold`); its loop selection here is 4.5…5 s.
@MainActor
final class TakePlayButtonTests: XCTestCase {
    private func takeFixture() async throws -> (M9Fixture, Take) {
        let fixture = try await M9TestSupport.makeFixtureWithCommittedTake(testCase: self, takeDuration: 3)
        return try (fixture, XCTUnwrap(fixture.viewModel.takes.first))
    }

    private func loop(_ take: Take) throws -> PracticeRegion {
        try PracticeRegion(start: take.region.start + 0.5, end: take.region.start + 1, sourceDuration: 30)
    }

    /// Waits for a `.playTake` sent after `count` commands, and returns its start and loop.
    @discardableResult
    private func playTakeSent(
        _ fixture: M9Fixture,
        after count: Int
    ) async -> (from: TimeInterval, loop: PracticeRegion?)? {
        var sent: (TimeInterval, PracticeRegion?)?
        await M9TestSupport.waitUntilAsync {
            for command in await fixture.audio.commands.dropFirst(count) {
                if case let .playTake(_, from, loop) = command {
                    sent = (from, loop)
                }
            }
            return sent != nil
        }
        return sent
    }

    @discardableResult
    private func pressPlay(_ fixture: M9Fixture, _ take: Take) async -> (from: TimeInterval, loop: PracticeRegion?)? {
        let count = await fixture.audio.commands.count
        fixture.viewModel.toggleTakePlayback(take)
        let sent = await playTakeSent(fixture, after: count)
        await M9TestSupport.waitUntil { fixture.viewModel.isPlaying && fixture.viewModel.pendingLocalSeek == nil }
        return sent
    }

    /// A paused click on the take's lane (what `TakeWaveformLane` runs).
    private func click(_ fixture: M9Fixture, _ take: Take, at sourceTime: TimeInterval) async {
        fixture.viewModel.seekTakeLane(take, to: sourceTime)
        await M9TestSupport.waitForCommand(.seek(sourceTime), audio: fixture.audio)
        await M9TestSupport.waitUntil { fixture.viewModel.pendingLocalSeek == nil }
    }

    private func assertLoop(_ sent: PracticeRegion?, _ start: TimeInterval, _ end: TimeInterval) {
        XCTAssertEqual(sent?.start ?? -1, start, accuracy: 1e-9)
        XCTAssertEqual(sent?.end ?? -1, end, accuracy: 1e-9)
    }

    func testClickAfterTheSelectionThenPlayStartsAtTheClick() async throws {
        let (fixture, take) = try await takeFixture()
        let model = fixture.viewModel
        try model.selectTakeLoopRegion(take, loop(take))
        await click(fixture, take, at: take.region.start + 1.2)

        let sent = await pressPlay(fixture, take)

        XCTAssertEqual(sent?.from ?? -1, 1.2, accuracy: 1e-9, "starts at the click, after the loop")
        assertLoop(sent?.loop, 0.5, 1) // the engine plays straight on to the end from there
        XCTAssertEqual(model.playhead, take.region.start + 1.2, accuracy: 1e-9, "no jump")
        XCTAssertEqual(model.takeLoopSelections[take.id]?.start, take.region.start + 0.5, "the loop stays")
    }

    func testClickBeforeTheSelectionThenPlayPlaysIntoTheLoop() async throws {
        let (fixture, take) = try await takeFixture()
        let model = fixture.viewModel
        try model.selectTakeLoopRegion(take, loop(take))
        await click(fixture, take, at: take.region.start + 0.2)

        let sent = await pressPlay(fixture, take)

        XCTAssertEqual(sent?.from ?? -1, 0.2, accuracy: 1e-9, "starts at the click, before the loop")
        assertLoop(sent?.loop, 0.5, 1) // the engine plays into the loop, then loops
        XCTAssertEqual(model.playhead, take.region.start + 0.2, accuracy: 1e-9)
    }

    func testANeverPlayedTakeStartsAtItsLoopStart() async throws {
        let (fixture, take) = try await takeFixture()
        let model = fixture.viewModel
        model.takeLoopSelections[take.id] = try loop(take) // a loop, but no playhead yet
        XCTAssertNil(model.takePlayheads[take.id])

        let sent = await pressPlay(fixture, take)

        XCTAssertEqual(sent?.from ?? -1, 0.5, accuracy: 1e-9)
        XCTAssertEqual(model.playhead, take.region.start + 0.5, accuracy: 1e-9)
    }

    func testANeverPlayedTakeWithoutALoopStartsAtZero() async throws {
        let (fixture, take) = try await takeFixture()

        let sent = await pressPlay(fixture, take)

        XCTAssertEqual(sent?.from ?? -1, 0, accuracy: 1e-9)
        XCTAssertNil(sent?.loop ?? nil)
    }

    func testAFinishedTakeRestartsAtItsLoopStartOrZero() async throws {
        let (fixture, take) = try await takeFixture()
        let model = fixture.viewModel
        await pressPlay(fixture, take)
        await fixture.audio.emit(.playheadChanged(1.4))
        await fixture.audio.emit(.playbackFinished)
        await M9TestSupport.waitUntil { !model.isPlaying }
        XCTAssertNil(model.takePlayheads[take.id], "reaching the end clears the take's playhead")

        let again = await pressPlay(fixture, take)
        XCTAssertEqual(again?.from ?? -1, 0, accuracy: 1e-9, "no loop: from 0")

        model.takeLoopSelections[take.id] = try loop(take)
        await fixture.audio.emit(.playbackFinished)
        await M9TestSupport.waitUntil { !model.isPlaying }
        let withLoop = await pressPlay(fixture, take)
        XCTAssertEqual(withLoop?.from ?? -1, 0.5, accuracy: 1e-9, "with a loop: from its start")
    }

    func testPausingThenPlayResumesWhereThePlaybackGotTo() async throws {
        let (fixture, take) = try await takeFixture()
        let model = fixture.viewModel
        await pressPlay(fixture, take)
        await fixture.audio.emit(.playheadChanged(0.8))
        await M9TestSupport.waitUntil { abs(model.playhead - (take.region.start + 0.8)) < 1e-9 }
        model.toggleTakePlayback(take) // pause
        await M9TestSupport.waitUntil { !model.isPlaying }

        let sent = await pressPlay(fixture, take)

        XCTAssertEqual(sent?.from ?? -1, 0.8, accuracy: 1e-9)
    }

    func testStalePositionsWhileThePlayButtonStartsAreIgnored() async throws {
        let (fixture, take) = try await takeFixture()
        let model = fixture.viewModel
        await click(fixture, take, at: take.region.start + 1)
        await fixture.audio.holdNextPlayTake()
        model.toggleTakePlayback(take)
        await M9TestSupport.waitUntil { model.pendingLocalSeek != nil }

        await fixture.audio.emit(.playheadChanged(0.1)) // from before the start
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(model.playhead, take.region.start + 1, accuracy: 1e-9)
        XCTAssertEqual(model.takePlayheads[take.id] ?? -1, 1, accuracy: 1e-9)

        await fixture.audio.releaseHeldSeek()
        await M9TestSupport.waitUntil { model.pendingLocalSeek == nil }
    }

    // MARK: - A take with a measured offset: the playhead never jumps by it

    func testWithAnOffsetClickThenPlayReportsTheClickTime() async throws {
        let (fixture, take) = try await takeFixture()
        let model = fixture.viewModel
        model.takeOffsets[take.id] = 0.2 // the original starts 0.2 s into the take file
        let spot = take.region.start + 0.6
        await click(fixture, take, at: spot)

        let sent = await pressPlay(fixture, take)
        XCTAssertEqual(sent?.from ?? -1, 0.8, accuracy: 1e-9, "take time includes the offset")
        XCTAssertEqual(model.playhead, spot, accuracy: 1e-9)

        await fixture.audio.emit(.playheadChanged(0.8)) // the engine reports where it starts
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(model.playhead, spot, accuracy: 1e-9, "no jump by the offset")
    }

    func testWithAnOffsetAClickOnThePlayingTakeReportsTheClickTime() async throws {
        let (fixture, take) = try await takeFixture()
        let model = fixture.viewModel
        model.takeOffsets[take.id] = 0.2
        await pressPlay(fixture, take)
        let count = await fixture.audio.commands.count
        let spot = take.region.start + 1

        model.seekTakeLane(take, to: spot)
        let sent = await playTakeSent(fixture, after: count)
        await M9TestSupport.waitUntil { model.pendingLocalSeek == nil }
        XCTAssertEqual(sent?.from ?? -1, 1.2, accuracy: 1e-9)

        await fixture.audio.emit(.playheadChanged(1.2))
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(model.playhead, spot, accuracy: 1e-9, "no jump by the offset")
    }

    func testWithAnOffsetTheLoopPlaysWhatTheSelectionShows() async throws {
        let (fixture, take) = try await takeFixture()
        let model = fixture.viewModel
        model.takeOffsets[take.id] = 0.2
        model.takeLoopSelections[take.id] = try loop(take)

        let sent = await pressPlay(fixture, take)

        assertLoop(sent?.loop, 0.7, 1.2)
        XCTAssertEqual(sent?.from ?? -1, 0.7, accuracy: 1e-9)
        XCTAssertEqual(model.playhead, take.region.start + 0.5, accuracy: 1e-9, "at the selection start")
    }

    func testRowClickAfterALaneClickMakesPlayStartAtTheTakesStart() async throws {
        let (fixture, take) = try await takeFixture()
        let model = fixture.viewModel
        model.takeOffsets[take.id] = 0.2
        await click(fixture, take, at: take.region.start + 1) // mid-take

        model.selectTake(take) // the row: the playhead jumps to the take's start
        await M9TestSupport.waitForCommand(.seek(take.region.start), audio: fixture.audio)
        await M9TestSupport.waitUntil { model.pendingLocalSeek == nil }
        let sent = await pressPlay(fixture, take)

        XCTAssertEqual(sent?.from ?? -1, 0.2, accuracy: 1e-9, "the take's start, in take time with the offset")
        XCTAssertEqual(model.playhead, take.region.start, accuracy: 1e-9)
        await fixture.audio.emit(.playheadChanged(0.2))
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(model.playhead, take.region.start, accuracy: 1e-9, "no jump")
    }

    func testAnOriginalLaneOrSentenceClickInsideTheTakeMovesItsPlayheadThere() async throws {
        let (fixture, take) = try await takeFixture()
        let model = fixture.viewModel
        model.takeOffsets[take.id] = 0.2
        await click(fixture, take, at: take.region.start + 0.3) // on the take's lane

        model.seekTimeline(take.region.start + 1) // then on the original lane, inside the take
        await M9TestSupport.waitForCommand(.seek(take.region.start + 1), audio: fixture.audio)
        await M9TestSupport.waitUntil { model.pendingLocalSeek == nil }
        let fromLane = await pressPlay(fixture, take)
        XCTAssertEqual(fromLane?.from ?? -1, 1.2, accuracy: 1e-9, "where the playhead is, with the offset")
        XCTAssertEqual(model.playhead, take.region.start + 1, accuracy: 1e-9)

        model.toggleTakePlayback(take) // pause
        await M9TestSupport.waitUntil { !model.isPlaying }
        model.seek(to: take.region.start + 0.6) // a sentence click
        await M9TestSupport.waitForCommand(.seek(take.region.start + 0.6), audio: fixture.audio)
        await M9TestSupport.waitUntil { model.pendingLocalSeek == nil }
        let fromSentence = await pressPlay(fixture, take)
        XCTAssertEqual(fromSentence?.from ?? -1, 0.8, accuracy: 1e-9)
        XCTAssertEqual(model.playhead, take.region.start + 0.6, accuracy: 1e-9)
    }

    func testAClickOutsideTheTakeMakesPlayStartAtItsLoopStartOrZero() async throws {
        let (fixture, take) = try await takeFixture()
        let model = fixture.viewModel
        await click(fixture, take, at: take.region.start + 1.2)
        model.seekTimeline(20) // outside the take
        await M9TestSupport.waitForCommand(.seek(20), audio: fixture.audio)
        await M9TestSupport.waitUntil { model.pendingLocalSeek == nil }
        XCTAssertNil(model.takePlayheads[take.id])

        let noLoop = await pressPlay(fixture, take)
        XCTAssertEqual(noLoop?.from ?? -1, 0, accuracy: 1e-9, "no loop: from 0")

        model.toggleTakePlayback(take) // pause
        await M9TestSupport.waitUntil { !model.isPlaying }
        model.takeLoopSelections[take.id] = try loop(take)
        await click(fixture, take, at: take.region.start + 1.2)
        model.seekTimeline(20)
        await M9TestSupport.waitUntil { model.pendingLocalSeek == nil && model.takePlayheads[take.id] == nil }
        let withLoop = await pressPlay(fixture, take)
        XCTAssertEqual(withLoop?.from ?? -1, 0.5, accuracy: 1e-9, "with a loop: from its start")
    }

    // MARK: - The original paused: no matter how the playhead got there

    /// Plays the original from `start`, lets the engine report `reached`, then pauses.
    private func playOriginalThenPause(_ fixture: M9Fixture, from start: TimeInterval, reached: TimeInterval) async {
        let model = fixture.viewModel
        model.seek(to: start)
        await M9TestSupport.waitUntil { model.pendingLocalSeek == nil }
        model.togglePlayback()
        await M9TestSupport.waitUntil { model.isPlaying && model.playingTakeID == nil }
        await fixture.audio.emit(.playheadChanged(reached))
        await M9TestSupport.waitUntil { abs(model.playhead - reached) < 1e-9 }
        model.togglePlayback() // pause (Space)
        await M9TestSupport.waitUntil { !model.isPlaying }
    }

    func testPausingTheOriginalInsideTheTakeMakesPlayStartThere() async throws {
        let (fixture, take) = try await takeFixture()
        let model = fixture.viewModel
        model.takeOffsets[take.id] = 0.2
        await playOriginalThenPause(fixture, from: 1, reached: take.region.start + 0.9)

        let sent = await pressPlay(fixture, take)

        XCTAssertEqual(sent?.from ?? -1, 1.1, accuracy: 1e-9, "the paused spot, with the offset")
        XCTAssertEqual(model.playhead, take.region.start + 0.9, accuracy: 1e-9, "no jump")
    }

    func testPausingTheOriginalPastTheTakeMakesPlayStartAtItsLoopStartOrZero() async throws {
        let (fixture, take) = try await takeFixture()
        let model = fixture.viewModel
        await click(fixture, take, at: take.region.start + 1) // an older spot on the take
        await playOriginalThenPause(fixture, from: take.region.start + 1, reached: 12)
        XCTAssertNil(model.takePlayheads[take.id])

        let noLoop = await pressPlay(fixture, take)
        XCTAssertEqual(noLoop?.from ?? -1, 0, accuracy: 1e-9, "no loop: from 0")

        model.toggleTakePlayback(take) // pause the take
        await M9TestSupport.waitUntil { !model.isPlaying }
        model.takeLoopSelections[take.id] = try loop(take)
        await playOriginalThenPause(fixture, from: take.region.start + 1, reached: 12)
        let withLoop = await pressPlay(fixture, take)
        XCTAssertEqual(withLoop?.from ?? -1, 0.5, accuracy: 1e-9, "with a loop: from its start")
    }

    func testPressingTheTakesPlayWhileTheOriginalPlaysInsideItStartsThere() async throws {
        let (fixture, take) = try await takeFixture()
        let model = fixture.viewModel
        model.seek(to: 1)
        await M9TestSupport.waitUntil { model.pendingLocalSeek == nil }
        model.togglePlayback()
        await M9TestSupport.waitUntil { model.isPlaying }
        await fixture.audio.emit(.playheadChanged(take.region.start + 0.7))
        await M9TestSupport.waitUntil { abs(model.playhead - (take.region.start + 0.7)) < 1e-9 }

        let sent = await pressPlay(fixture, take)

        XCTAssertEqual(sent?.from ?? -1, 0.7, accuracy: 1e-9)
    }

    // MARK: - A take paused or ended: the other takes follow the playhead on screen

    func testPausingATakeInsideAnotherTakeMakesItsPlayStartThere() async throws {
        let (fixture, takeA) = try await takeFixture() // 4…7 s
        let model = fixture.viewModel
        let takeB = try await M9TestSupport.commitAdditionalTake(
            fixture: fixture,
            region: PracticeRegion(start: 4.5, end: 8.5, sourceDuration: 30),
            sequence: takeA.sequence + 1,
            createdAt: Date()
        )
        await model.refreshTakes()
        model.takeOffsets[takeB.id] = 0.1
        await pressPlay(fixture, takeA)
        await fixture.audio.emit(.playheadChanged(1.2)) // take A at 5.2 s on screen
        await M9TestSupport.waitUntil { abs(model.playhead - 5.2) < 1e-9 }
        model.toggleTakePlayback(takeA) // pause A
        await M9TestSupport.waitUntil { !model.isPlaying }
        XCTAssertEqual(model.takePlayheads[takeA.id] ?? -1, 1.2, accuracy: 1e-9, "A keeps its own spot")

        let fromPause = await pressPlay(fixture, takeB)
        XCTAssertEqual(fromPause?.from ?? -1, 0.8, accuracy: 1e-9, "5.2 s in B's time, with B's offset")
        XCTAssertEqual(model.playhead, 5.2, accuracy: 1e-9, "no jump")

        model.toggleTakePlayback(takeB) // pause B, then let A play to its end
        await M9TestSupport.waitUntil { !model.isPlaying }
        await pressPlay(fixture, takeA)
        await fixture.audio.emit(.playbackFinished)
        await M9TestSupport.waitUntil { !model.isPlaying }
        XCTAssertNil(model.takePlayheads[takeA.id], "A reached its end: it restarts from 0")
        let fromEnd = await pressPlay(fixture, takeB)
        XCTAssertEqual(fromEnd?.from ?? -1, 2.6, accuracy: 1e-9, "A's end (7 s) in B's time")
    }
}
