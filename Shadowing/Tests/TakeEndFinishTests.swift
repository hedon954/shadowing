import Foundation
@testable import Shadowing
import XCTest

/// Designer rule: a take playhead less than `takeEndFinishThreshold` (0.5 s) before the take's
/// end, in the take's own time after the offset, counts as finished, so the take's Play starts
/// from its loop start (or 0), never a tiny blip at the end.
/// Fixture take: waveform 4…7 s, 3 s long; its loop selection here is 4.5…5 s.
@MainActor
final class TakeEndFinishTests: XCTestCase {
    private func takeFixture() async throws -> (M9Fixture, Take) {
        let fixture = try await M9TestSupport.makeFixtureWithCommittedTake(testCase: self, takeDuration: 3)
        return try (fixture, XCTUnwrap(fixture.viewModel.takes.first))
    }

    private func loop(_ take: Take) throws -> PracticeRegion {
        try PracticeRegion(start: take.region.start + 0.5, end: take.region.start + 1, sourceDuration: 30)
    }

    /// Presses the take's Play and returns the start sent with its `.playTake`.
    @discardableResult
    private func pressPlay(_ fixture: M9Fixture, _ take: Take) async -> (from: TimeInterval, loop: PracticeRegion?)? {
        let count = await fixture.audio.commands.count
        fixture.viewModel.toggleTakePlayback(take)
        var sent: (TimeInterval, PracticeRegion?)?
        await M9TestSupport.waitUntilAsync {
            for command in await fixture.audio.commands.dropFirst(count) {
                if case let .playTake(_, from, loop) = command {
                    sent = (from, loop)
                }
            }
            return sent != nil
        }
        await M9TestSupport.waitUntil { fixture.viewModel.isPlaying && fixture.viewModel.pendingLocalSeek == nil }
        return sent
    }

    /// Parks the playhead (a click on the original lane) and returns where the take's Play
    /// starts, then pauses it again.
    private func playAfterParking(
        _ fixture: M9Fixture,
        _ take: Take,
        at sourceTime: TimeInterval
    ) async -> TimeInterval? {
        let model = fixture.viewModel
        model.seekTimeline(sourceTime)
        await M9TestSupport.waitForCommand(.seek(sourceTime), audio: fixture.audio)
        await M9TestSupport.waitUntil { model.pendingLocalSeek == nil }
        let sent = await pressPlay(fixture, take)
        model.toggleTakePlayback(take)
        await M9TestSupport.waitUntil { !model.isPlaying }
        return sent?.from
    }

    func testWithANegativeOffsetThePlayheadAtTheTakesEndRestartsIt() async throws {
        let (fixture, take) = try await takeFixture()
        let model = fixture.viewModel
        model.takeOffsets[take.id] = -0.2 // take time = waveform time - 0.2 s

        let atEnd = await playAfterParking(fixture, take, at: take.region.end) // take time 2.8
        XCTAssertEqual(atEnd ?? -1, 0, accuracy: 1e-9, "not a 0.2 s blip at the end")
        let justBefore = await playAfterParking(fixture, take, at: take.region.end - 0.1) // 2.7
        XCTAssertEqual(justBefore ?? -1, 0, accuracy: 1e-9)

        model.takeLoopSelections[take.id] = try loop(take)
        let withLoop = await playAfterParking(fixture, take, at: take.region.end)
        XCTAssertEqual(withLoop ?? -1, 0.3, accuracy: 1e-9, "the loop start (4.5 s) in take time")
    }

    func testAPlayheadLessThanHalfASecondBeforeTheEndIsCleared() async throws {
        let (fixture, take) = try await takeFixture()
        let model = fixture.viewModel

        let near = await playAfterParking(fixture, take, at: take.region.end - 0.4) // 2.6
        XCTAssertEqual(near ?? -1, 0, accuracy: 1e-9, "0.4 s before the end: finished, from 0")
        let far = await playAfterParking(fixture, take, at: take.region.end - 0.6) // 2.4
        XCTAssertEqual(far ?? -1, 2.4, accuracy: 1e-9, "0.6 s before the end: kept")

        model.takeOffsets[take.id] = 0.2 // the same waveform spot is 2.6 in take time
        let shifted = await playAfterParking(fixture, take, at: take.region.end - 0.6)
        XCTAssertEqual(shifted ?? -1, 0, accuracy: 1e-9, "measured in take time, after the offset")
    }

    func testATakePausedByItsOwnButtonNearItsEndRestarts() async throws {
        let (fixture, take) = try await takeFixture()
        let model = fixture.viewModel
        for (loop, expected) in try [(nil, 0.0), (loop(take), 0.5)] {
            model.takeLoopSelections[take.id] = loop
            await pressPlay(fixture, take)
            await fixture.audio.emit(.playheadChanged(2.7)) // 0.3 s before its end
            await M9TestSupport.waitUntil { abs(model.playhead - (take.region.start + 2.7)) < 1e-9 }
            model.toggleTakePlayback(take) // its own pause button
            await M9TestSupport.waitUntil { !model.isPlaying }
            XCTAssertNil(model.takePlayheads[take.id])

            let sent = await pressPlay(fixture, take)
            XCTAssertEqual(sent?.from ?? -1, expected, accuracy: 1e-9, "from 0, or the loop start")
            model.toggleTakePlayback(take)
            await M9TestSupport.waitUntil { !model.isPlaying }
        }
    }
}
