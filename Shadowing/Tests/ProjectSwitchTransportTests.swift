import Foundation
@testable import Shadowing
import XCTest

/// Switching project: the old practice closes (cancelling its event loop) and the new one
/// subscribes to the same engine. Its playhead must keep moving.
@MainActor
final class ProjectSwitchTransportTests: XCTestCase {
    func testCancellingOneSubscriberKeepsOtherStreamsAlive() async {
        let hub = PracticeAudioEventHub()
        let old = hub.makeStream()
        let oldLoop = Task {
            for await _ in old {}
        }
        await Task.yield()
        oldLoop.cancel()
        _ = await oldLoop.value
        XCTAssertEqual(hub.subscriberCount, 0, "a cancelled subscriber is dropped")

        let next = hub.makeStream()
        hub.yield(.playheadChanged(4))
        hub.finish()
        var received: [PracticeAudioEvent] = []
        for await event in next {
            received.append(event)
        }
        XCTAssertEqual(received, [.playheadChanged(4)])
    }

    func testSwitchingProjectWhilePlayingKeepsPlayheadEventsFlowing() async throws {
        let audio = BroadcastingAudioClient()
        let projects = InMemoryProjectRepository(storage: InMemoryPersistence())
        let first = try await makeModel(audio: audio, projects: projects, name: "One.mp3")
        first.start()
        await M9TestSupport.waitUntil { audio.subscriberCount == 1 }
        first.togglePlayback()
        await M9TestSupport.waitUntil { first.isPlaying }
        audio.emit(.playheadChanged(3))
        await M9TestSupport.waitUntil { abs(first.playhead - 3) < 1e-9 }
        // Arm the gates a Compare restore and a waveform drag leave behind.
        first.restoringPlayheadAfterComparison = 3
        first.setTimelineGestureActive(true)

        await first.close()
        XCTAssertFalse(first.isPlaying)
        XCTAssertNil(first.restoringPlayheadAfterComparison)
        XCTAssertFalse(first.suspendPlayheadFollow)
        let pauses = await audio.commands.filter { $0 == .pause }.count
        XCTAssertGreaterThanOrEqual(pauses, 1, "closing pauses the engine")

        let second = try await makeModel(audio: audio, projects: projects, name: "Two.mp3")
        second.start()
        await M9TestSupport.waitUntil { audio.subscriberCount == 1 }
        XCTAssertFalse(second.isPlaying, "a switched-to project opens paused, showing Play")
        XCTAssertNil(second.comparison)
        XCTAssertNil(second.restoringPlayheadAfterComparison)

        second.togglePlayback()
        await M9TestSupport.waitUntil { second.isPlaying }
        for position in [1.0, 1.5, 2.0] {
            audio.emit(.playheadChanged(position))
            await M9TestSupport.waitUntil { abs(second.playhead - position) < 1e-9 }
        }
        XCTAssertEqual(second.playhead, 2, accuracy: 1e-9)
        await second.close()
    }

    private func makeModel(
        audio: BroadcastingAudioClient,
        projects: InMemoryProjectRepository,
        name: String
    ) async throws -> PracticeViewModel {
        let project = M9TestSupport.makeProject(name: name, openedAt: 100)
        try await projects.save(project)
        return PracticeViewModel(
            prepared: PreparedPractice(
                project: project,
                waveform: WaveformPresentation(peaks: Array(repeating: 0.5, count: 64), warning: nil)
            ),
            audioClient: audio,
            projects: projects,
            sessionPreparer: M9SessionPreparer()
        )
    }
}

/// Like the real engine: one shared event source, a fresh stream per subscriber.
private actor BroadcastingAudioClient: PracticeAudioClient {
    private(set) var commands: [PracticeAudioCommand] = []
    private let hub = PracticeAudioEventHub()

    nonisolated var subscriberCount: Int {
        hub.subscriberCount
    }

    func execute(_ command: PracticeAudioCommand) async throws {
        commands.append(command)
    }

    func eventStream() async -> AsyncStream<PracticeAudioEvent> {
        hub.makeStream()
    }

    nonisolated func emit(_ event: PracticeAudioEvent) {
        hub.yield(event)
    }
}
