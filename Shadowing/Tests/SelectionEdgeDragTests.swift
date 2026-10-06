import Foundation
@testable import Shadowing
import XCTest

/// Designer rule: dragging a selection edge only changes the selection. It never turns the
/// loop on; a loop that is on follows the new selection; the playhead stays.
@MainActor
final class SelectionEdgeDragTests: XCTestCase {
    private func region(_ start: TimeInterval, _ end: TimeInterval) throws -> PracticeRegion {
        try PracticeRegion(start: start, end: end, sourceDuration: 30)
    }

    /// The session is hydrated, then 4–7 s is selected with the loop on.
    private func looping() async throws -> M9Fixture {
        let fixture = try await M9TestSupport.makeFixture(testCase: self, selectRegion: false)
        let model = fixture.viewModel
        await M9TestSupport.waitUntil { model.revealToken > 0 }
        let selection = try region(4, 7)
        model.selectRegion(selection)
        await M9TestSupport.waitUntil { model.loopEnabled && model.pendingLocalSeek == nil }
        try await Task.sleep(for: .milliseconds(30))
        return fixture
    }

    /// A take with a loop at 4.2–5 s, once Compare has stopped and its restore is done.
    private func takeWithLoop() async throws -> (M9Fixture, Take) {
        let fixture = try await M9TestSupport.makeFixtureWithCommittedTake(testCase: self) // 4–5.5 s
        let model = fixture.viewModel
        model.stopComparison()
        let take = try XCTUnwrap(model.takes.first)
        let loop = try region(4.2, 5)
        model.selectTakeLoopRegion(take, loop)
        try await Task.sleep(for: .milliseconds(50))
        return (fixture, take)
    }

    private func isLoop(_ command: PracticeAudioCommand, _ start: TimeInterval, _ end: TimeInterval) -> Bool {
        guard case let .setLoop(loop?) = command else {
            return false
        }
        return abs(loop.start - start) < 1e-9 && abs(loop.end - end) < 1e-9
    }

    private func commands(of fixture: M9Fixture, after count: Int) async -> [PracticeAudioCommand] {
        await Array(fixture.audio.commands.dropFirst(count))
    }

    func testWithTheLoopOnTheLoopFollowsTheNewSelection() async throws {
        let fixture = try await looping()
        let model = fixture.viewModel
        let before = await fixture.audio.commands.count

        let resized = try region(3, 8)
        model.resizeRegion(resized)
        await M9TestSupport.waitUntil { model.region?.start == 3 }
        try await Task.sleep(for: .milliseconds(50))

        let sent = await commands(of: fixture, after: before)
        XCTAssertTrue(sent.contains { isLoop($0, 3, 8) }, "\(sent)")
        XCTAssertFalse(sent.contains {
            if case .seek = $0 {
                true
            } else {
                false
            }
        }, "\(sent)")
        XCTAssertTrue(model.loopEnabled)
        XCTAssertEqual(model.playhead, 4, accuracy: 1e-9, "the playhead stays")
    }

    func testWithTheLoopOffItStaysOff() async throws {
        let fixture = try await looping()
        let model = fixture.viewModel
        model.setLoopEnabled(false)
        await M9TestSupport.waitForCommand(.setLoop(nil), audio: fixture.audio)
        let before = await fixture.audio.commands.count

        let resized = try region(4, 9)
        model.resizeRegion(resized)
        await M9TestSupport.waitUntil { model.region?.end == 9 }
        try await Task.sleep(for: .milliseconds(50))

        let sent = await commands(of: fixture, after: before)
        XCTAssertFalse(model.loopEnabled, "an edge drag never turns the loop on")
        XCTAssertEqual(sent, [], "neither loop nor seek")
        XCTAssertEqual(model.playhead, 4, accuracy: 1e-9)
    }

    /// A new selection still turns the loop on (unchanged).
    func testANewSelectionStillTurnsTheLoopOn() async throws {
        let fixture = try await looping()
        let model = fixture.viewModel
        model.setLoopEnabled(false)
        await M9TestSupport.waitForCommand(.setLoop(nil), audio: fixture.audio)
        let selection = try region(10, 12)
        model.selectRegion(selection)
        await M9TestSupport.waitUntil { model.loopEnabled }
    }

    func testATakeLoopEdgeDragKeepsThePausedTakesPlayhead() async throws {
        let (fixture, take) = try await takeWithLoop()
        let model = fixture.viewModel
        let takePlayhead = model.takePlayheads[take.id]
        let before = await fixture.audio.commands.count

        let resized = try region(4.2, 5.3)
        model.resizeTakeLoopRegion(take, resized)
        try await Task.sleep(for: .milliseconds(50))

        XCTAssertEqual(try XCTUnwrap(model.takeLoopSelections[take.id]?.end), 5.3, accuracy: 1e-9)
        XCTAssertEqual(model.takePlayheads[take.id], takePlayhead, "the take's playhead stays")
        let sent = await commands(of: fixture, after: before)
        XCTAssertEqual(sent, [], "nothing plays")
    }

    func testAPlayingTakesLoopFollowsAndItPlaysOnFromWhereItIs() async throws {
        let (fixture, take) = try await takeWithLoop()
        let model = fixture.viewModel
        model.toggleTakePlayback(take)
        await M9TestSupport.waitUntil { model.isPlaying && model.pendingLocalSeek == nil }
        await fixture.audio.emit(.playheadChanged(0.4)) // 4.4 s
        await M9TestSupport.waitUntil { abs(model.playhead - 4.4) < 1e-9 }
        let before = await fixture.audio.commands.count

        let resized = try region(4.2, 5.3)
        model.resizeTakeLoopRegion(take, resized)
        await M9TestSupport.waitUntil { model.pendingLocalSeek == nil }
        try await Task.sleep(for: .milliseconds(30))

        let sent = await commands(of: fixture, after: before)
        let replays = sent.compactMap { command -> (TimeInterval, PracticeRegion?)? in
            if case let .playTake(_, from, loop) = command {
                (from, loop)
            } else {
                nil
            }
        }
        XCTAssertEqual(replays.count, 1, "\(sent)")
        XCTAssertEqual(try XCTUnwrap(replays.first).0, 0.4, accuracy: 1e-9, "plays on from where it is")
        XCTAssertEqual(try XCTUnwrap(replays.first?.1?.end), 1.3, accuracy: 1e-9, "the loop follows")
        XCTAssertEqual(model.playhead, 4.4, accuracy: 1e-9)
    }
}
