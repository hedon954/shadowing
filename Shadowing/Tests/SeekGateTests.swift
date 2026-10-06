import Foundation
@testable import Shadowing
import XCTest

/// A local seek holds back engine positions until the engine applied it (`pendingLocalSeek`).
/// The gate must open on every way the seek command can end, or the playhead freezes.
@MainActor
final class SeekGateTests: XCTestCase {
    private func playing() async throws -> M9Fixture {
        let fixture = try await M9TestSupport.makeFixture(testCase: self, selectRegion: false)
        let model = fixture.viewModel
        await M9TestSupport.waitUntil { model.revealToken > 0 }
        model.togglePlayback()
        await M9TestSupport.waitUntil { model.isPlaying }
        await fixture.audio.emit(.playheadChanged(10))
        await M9TestSupport.waitUntil { abs(model.playhead - 10) < 1e-9 }
        return fixture
    }

    private func assertPositionsFlow(_ fixture: M9Fixture, to position: TimeInterval) async {
        let model = fixture.viewModel
        await M9TestSupport.waitUntil { model.pendingLocalSeek == nil }
        XCTAssertNil(model.pendingLocalSeek, "the seek gate stayed closed")
        await fixture.audio.emit(.playheadChanged(position))
        await M9TestSupport.waitUntil { abs(model.playhead - position) < 1e-9 }
        XCTAssertEqual(model.playhead, position, accuracy: 1e-9, "engine positions are followed again")
    }

    func testAFailedSeekDoesNotFreezeThePlayhead() async throws {
        let fixture = try await playing()
        await fixture.audio.failNextSeek(with: TestDoubleError.forcedFailure)
        fixture.viewModel.seek(to: 21)
        await M9TestSupport.waitForCommand(.seek(21), audio: fixture.audio)
        await assertPositionsFlow(fixture, to: 11.5)
    }

    func testASeekCancelledInFlightDoesNotFreezeThePlayhead() async throws {
        let fixture = try await playing()
        let model = fixture.viewModel
        await fixture.audio.holdNextSeek()
        model.seek(to: 21)
        await M9TestSupport.waitForCommand(.seek(21), audio: fixture.audio)
        model.commandTask?.cancel()
        await fixture.audio.releaseHeldSeek()
        await assertPositionsFlow(fixture, to: 21.5)
    }

    func testASeekCancelledBeforeItRanDoesNotFreezeThePlayhead() async throws {
        let fixture = try await playing()
        let model = fixture.viewModel
        await fixture.audio.holdNextSeek()
        model.seek(to: 21)
        await M9TestSupport.waitForCommand(.seek(21), audio: fixture.audio)
        model.seek(to: 25) // queued behind the held seek
        XCTAssertEqual(model.pendingLocalSeek, 25)
        model.commandTask?.cancel() // the queued seek never reaches the engine
        await fixture.audio.releaseHeldSeek()
        await assertPositionsFlow(fixture, to: 25.5)
        let commands = await fixture.audio.commands
        XCTAssertFalse(commands.contains(.seek(25)))
    }

    /// The practice subscribes the moment it starts; events sent right after `start()`, before
    /// its listening task first runs, are not lost.
    func testStartSubscribesToEngineEventsImmediately() async {
        let prepared = M7TestSupport.makePreparedPractice(playhead: 0)
        let audio = HubAudioClient()
        let model = PracticeViewModel(
            prepared: prepared,
            audioClient: audio,
            projects: InMemoryProjectRepository(storage: InMemoryPersistence()),
            sessionPreparer: FixedSessionPreparer(prepared: prepared)
        )
        model.start()
        XCTAssertEqual(audio.subscriberCount, 1, "subscribed synchronously in start()")
        audio.emit(.playheadChanged(4.2))
        await M9TestSupport.waitUntil { abs(model.playhead - 4.2) < 1e-9 }
        XCTAssertEqual(model.playhead, 4.2, accuracy: 1e-9)
        await model.close()
    }
}

/// Per-subscriber streams like the real engine: a subscriber only gets events sent after it
/// subscribed.
private actor HubAudioClient: PracticeAudioClient {
    private let hub = PracticeAudioEventHub()

    nonisolated var subscriberCount: Int {
        hub.subscriberCount
    }

    func execute(_: PracticeAudioCommand) async throws {}

    nonisolated func eventStream() -> AsyncStream<PracticeAudioEvent> {
        hub.makeStream()
    }

    nonisolated func emit(_ event: PracticeAudioEvent) {
        hub.yield(event)
    }
}
