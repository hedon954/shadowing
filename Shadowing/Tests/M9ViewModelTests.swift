import Foundation
@testable import Shadowing
import XCTest

@MainActor
final class M9ViewModelTests: XCTestCase {
    func testKeepThisTakePersistsWithoutDeletingOthers() async throws {
        let fixture = try await M9TestSupport.makeFixtureWithCommittedTake(testCase: self)
        let first = try XCTUnwrap(fixture.viewModel.activeTake)
        let second = try await M9TestSupport.commitAdditionalTake(
            fixture: fixture,
            region: fixture.region,
            sequence: 2,
            createdAt: Date(timeIntervalSince1970: 400)
        )
        await fixture.viewModel.refreshTakes()
        fixture.viewModel.selectTake(second)

        fixture.viewModel.keepThisTake()
        await M9TestSupport.waitUntil {
            fixture.viewModel.project.keptTakeID == second.id
        }
        await M9TestSupport.waitUntilAsync {
            let stored = try? await fixture.projects.project(id: fixture.project.id)
            return stored?.keptTakeID == second.id
        }

        let stored = try await fixture.projects.project(id: fixture.project.id)
        XCTAssertEqual(stored?.keptTakeID, second.id)
        XCTAssertEqual(Set(fixture.viewModel.takes.map(\.id)), Set([first.id, second.id]))

        fixture.viewModel.selectTake(first)
        fixture.viewModel.keepThisTake()
        await M9TestSupport.waitUntilAsync {
            let stored = try? await fixture.projects.project(id: fixture.project.id)
            return stored?.keptTakeID == first.id
        }
        XCTAssertEqual(fixture.viewModel.takes.count, 2)
    }

    func testTakePlaybackIssuesPlayTakeAndStopsAtEnd() async throws {
        let fixture = try await M9TestSupport.makeFixtureWithCommittedTake(testCase: self)
        let take = try XCTUnwrap(fixture.viewModel.activeTake)
        fixture.viewModel.setLoopEnabled(false)

        fixture.viewModel.toggleTakePlayback(take)
        await M9TestSupport.waitForCommand(
            .playTake(takeID: take.id, from: 0, loop: nil),
            audio: fixture.audio
        )
        XCTAssertEqual(fixture.viewModel.playingTakeID, take.id)

        await fixture.audio.emit(.playheadChanged(take.duration))
        await fixture.audio.emit(.playbackFinished)
        await M9TestSupport.waitUntil {
            fixture.viewModel.playingTakeID == nil && fixture.viewModel.isPlaying == false
        }
        XCTAssertEqual(fixture.viewModel.playhead, take.region.end)

        fixture.viewModel.seekTimeline(take.region.start)
        await M9TestSupport.waitForCommand(
            .seek(take.region.start),
            audio: fixture.audio
        )
        await fixture.audio.emit(.playheadChanged(take.region.start))
        await M9TestSupport.waitUntil {
            abs(fixture.viewModel.playhead - take.region.start) < 0.001
        }
        XCTAssertEqual(fixture.viewModel.playhead, take.region.start, accuracy: 0.001)

        fixture.viewModel.seekTimeline(0)
        await M9TestSupport.waitForCommand(.seek(0), audio: fixture.audio)
        await fixture.audio.emit(.playheadChanged(0))
        await M9TestSupport.waitUntil {
            abs(fixture.viewModel.playhead - 0) < 0.001
        }
        XCTAssertEqual(fixture.viewModel.playhead, 0, accuracy: 0.001)
    }

    func testTakePlaybackLoopsOverlappingPracticeRegion() async throws {
        let fixture = try await M9TestSupport.makeFixtureWithCommittedTake(testCase: self)
        let take = try XCTUnwrap(fixture.viewModel.activeTake)
        let selection = try PracticeRegion(
            start: take.region.start,
            end: min(take.region.start + 1.0, take.region.end),
            sourceDuration: 30
        )
        fixture.viewModel.setLoopEnabled(false)
        fixture.viewModel.selectTakeLoopRegion(take, selection)
        let expectedLocal = try XCTUnwrap(
            TakePlaybackTiming.localLoopRegion(
                selection: selection,
                takeRegion: take.region
            )
        )

        fixture.viewModel.toggleTakePlayback(take)
        await M9TestSupport.waitUntilAsync {
            let commands = await fixture.audio.commands
            return commands.contains { command in
                guard case let .playTake(takeID, from, loop) = command,
                      takeID == take.id,
                      let loop
                else {
                    return false
                }
                return abs(from - expectedLocal.start) < 0.001
                    && abs(loop.start - expectedLocal.start) < 0.001
                    && abs(loop.end - expectedLocal.end) < 0.001
            }
        }
        XCTAssertEqual(
            fixture.viewModel.playhead,
            take.region.start + expectedLocal.start,
            accuracy: 0.001
        )
    }

    func testTakeLoopSelectionIsIndependentFromOriginalRegion() async throws {
        let fixture = try await M9TestSupport.makeFixtureWithCommittedTake(testCase: self)
        let take = try XCTUnwrap(fixture.viewModel.activeTake)
        let original = try XCTUnwrap(fixture.viewModel.region)
        let takeSelection = try PracticeRegion(
            start: take.region.start,
            end: min(take.region.start + 0.8, take.region.end),
            sourceDuration: 30
        )

        fixture.viewModel.selectTakeLoopRegion(take, takeSelection)

        XCTAssertEqual(fixture.viewModel.region, original)
        let stored = try XCTUnwrap(fixture.viewModel.takeLoopSelections[take.id])
        XCTAssertEqual(stored.start, takeSelection.start, accuracy: 0.001)
        XCTAssertEqual(stored.end, takeSelection.end, accuracy: 0.001)

        fixture.viewModel.clearTakeLoopRegion(take)
        XCTAssertNil(fixture.viewModel.takeLoopSelections[take.id])
        XCTAssertEqual(fixture.viewModel.region, original)
    }

    func testUpdatingTakeLoopWhilePlayingRestartsWithNewLoop() async throws {
        let fixture = try await M9TestSupport.makeFixtureWithCommittedTake(testCase: self)
        let take = try XCTUnwrap(fixture.viewModel.activeTake)
        let first = try PracticeRegion(
            start: take.region.start,
            end: min(take.region.start + 1.0, take.region.end),
            sourceDuration: 30
        )
        let second = try PracticeRegion(
            start: take.region.start,
            end: min(take.region.start + 0.7, take.region.end),
            sourceDuration: 30
        )
        let expectedLocal = try XCTUnwrap(
            TakePlaybackTiming.localLoopRegion(
                selection: second,
                takeRegion: take.region
            )
        )
        fixture.viewModel.selectTakeLoopRegion(take, first)
        fixture.viewModel.toggleTakePlayback(take)
        await M9TestSupport.waitUntilAsync {
            let commands = await fixture.audio.commands
            return commands.contains { command in
                if case let .playTake(takeID, _, _) = command {
                    return takeID == take.id
                }
                return false
            }
        }

        let commandCount = await fixture.audio.commands.count
        fixture.viewModel.selectTakeLoopRegion(take, second)
        await M9TestSupport.waitUntilAsync {
            let commands = await fixture.audio.commands
            return commands.dropFirst(commandCount).contains { command in
                guard case let .playTake(takeID, _, loop) = command,
                      takeID == take.id,
                      let loop
                else {
                    return false
                }
                return abs(loop.start - expectedLocal.start) < 0.001
                    && abs(loop.end - expectedLocal.end) < 0.001
            }
        }
        let stored = try XCTUnwrap(fixture.viewModel.takeLoopSelections[take.id])
        XCTAssertEqual(stored.end, second.end, accuracy: 0.001)
    }

    func testTakePlaybackFocusesViewportWhenTakeIsOffscreen() async throws {
        let fixture = try await M9TestSupport.makeFixtureWithCommittedTake(testCase: self)
        let take = try XCTUnwrap(fixture.viewModel.activeTake)
        fixture.viewModel.setLoopEnabled(false)
        fixture.viewModel.setTimelineViewport(
            TimelineViewport(start: 20, duration: 5, sourceDuration: 30)
        )
        XCTAssertFalse(fixture.viewModel.timelineViewport.contains(take.region.start))

        fixture.viewModel.toggleTakePlayback(take)
        await M9TestSupport.waitForCommand(
            .playTake(takeID: take.id, from: 0, loop: nil),
            audio: fixture.audio
        )

        XCTAssertTrue(fixture.viewModel.timelineViewport.contains(take.region.start))
        XCTAssertTrue(
            fixture.viewModel.timelineViewport.contains(
                min(take.region.end, take.region.start + 0.1)
            )
        )
    }

    func testOriginalTransportIgnoresTakeMode() async throws {
        let fixture = try await M9TestSupport.makeFixtureWithCommittedTake(testCase: self)
        fixture.viewModel.seekTimeline(12)
        fixture.viewModel.togglePlayback()
        await M9TestSupport.waitForCommand(
            .playOriginal(region: nil, from: 12, rate: 1),
            audio: fixture.audio
        )
        XCTAssertNil(fixture.viewModel.playingTakeID)
    }

    func testRecordingCountdownAndPlayOriginalReadFromSettings() async throws {
        let storage = InMemoryPersistence()
        let settings = InMemorySettingsStore(storage: storage)
        try await settings.set(
            AppSettings(
                countdownSeconds: 1,
                playOriginalWhileRecording: false,
                defaultPlaybackRate: 0.75
            ),
            for: AppSettings.storeKey
        )
        let fixture = try await M9TestSupport.makeFixture(
            testCase: self,
            settings: settings,
            countdownSeconds: 3,
            playOriginalWhileRecording: true
        )
        let commandCountBefore = await fixture.audio.commands.count
        fixture.viewModel.startRecording()

        await M9TestSupport.waitUntil {
            if case .countingDown(1) = fixture.viewModel.recordingPresentation {
                return true
            }
            return false
        }

        let temporaryURL = await M9TestSupport.waitForBeginRecording(
            audio: fixture.audio,
            afterCommandCount: commandCountBefore
        )
        let commands = await fixture.audio.commands
        let begin = commands.reversed().first { command in
            if case .beginRecording = command {
                return true
            }
            return false
        }
        guard case let .beginRecording(_, url, playOriginal) = begin else {
            return XCTFail("Expected beginRecording")
        }
        XCTAssertEqual(url, temporaryURL)
        XCTAssertFalse(playOriginal)
    }
}
