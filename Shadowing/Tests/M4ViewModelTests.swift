import Foundation
@testable import Shadowing
import XCTest

final class M4ViewModelTests: XCTestCase {
    @MainActor
    func testLoopCannotBeEnabledWithoutARegion() async {
        let audio = PracticeAudioClientSpy()
        let viewModel = makeViewModel(audio: audio)

        viewModel.setLoopEnabled(true)
        await assertCommandCount(0, audio: audio)

        XCTAssertFalse(viewModel.loopEnabled)
        XCTAssertFalse(viewModel.canToggleLoop)
    }

    @MainActor
    func testSelectingRegionSeeksToStartAndEnablesLoop() async throws {
        let audio = PracticeAudioClientSpy()
        let viewModel = makeViewModel(audio: audio)
        let region = try PracticeRegion(start: 12, end: 20, sourceDuration: 120)

        viewModel.selectRegion(region)
        await waitForCommandCount(2, audio: audio)

        XCTAssertEqual(viewModel.region, region)
        XCTAssertEqual(viewModel.playhead, 12)
        XCTAssertTrue(viewModel.loopEnabled)
        XCTAssertTrue(viewModel.canToggleLoop)
        let commands = await audio.commands
        XCTAssertEqual(
            commands,
            [.setLoop(region), .seek(12)]
        )
    }

    @MainActor
    func testUpdatingRegionWhileLoopingKeepsPlayheadWhenStillInside() async throws {
        let audio = PracticeAudioClientSpy()
        let viewModel = makeViewModel(audio: audio)
        let initial = try PracticeRegion(start: 12, end: 20, sourceDuration: 120)
        let updated = try PracticeRegion(start: 12, end: 18, sourceDuration: 120)
        viewModel.selectRegion(initial)
        await waitForCommandCount(2, audio: audio)
        viewModel.togglePlayback()
        await waitForCommandCount(3, audio: audio)
        for _ in 0 ..< 20 where !viewModel.isPlaying {
            await Task.yield()
        }
        viewModel.playhead = 15
        viewModel.project.playhead = 15

        viewModel.selectRegion(updated)
        await waitForCommandCount(5, audio: audio)

        XCTAssertEqual(viewModel.region, updated)
        XCTAssertEqual(viewModel.playhead, 15, accuracy: 0.001)
        let commands = await audio.commands
        XCTAssertEqual(Array(commands.suffix(2)), [.setLoop(updated), .seek(15)])
    }

    @MainActor
    func testUpdatingRegionWhileLoopingSeeksToStartWhenOutside() async throws {
        let audio = PracticeAudioClientSpy()
        let viewModel = makeViewModel(audio: audio)
        let initial = try PracticeRegion(start: 12, end: 20, sourceDuration: 120)
        let updated = try PracticeRegion(start: 12, end: 14, sourceDuration: 120)
        viewModel.selectRegion(initial)
        await waitForCommandCount(2, audio: audio)
        viewModel.togglePlayback()
        await waitForCommandCount(3, audio: audio)
        for _ in 0 ..< 20 where !viewModel.isPlaying {
            await Task.yield()
        }
        viewModel.playhead = 16
        viewModel.project.playhead = 16

        viewModel.selectRegion(updated)
        await waitForCommandCount(5, audio: audio)

        XCTAssertEqual(viewModel.region, updated)
        XCTAssertEqual(viewModel.playhead, 12, accuracy: 0.001)
        let commands = await audio.commands
        XCTAssertEqual(Array(commands.suffix(2)), [.setLoop(updated), .seek(12)])
    }

    @MainActor
    func testClearingRegionDisablesLoopAndRemovesSelection() async throws {
        let audio = PracticeAudioClientSpy()
        let viewModel = makeViewModel(audio: audio)
        let region = try PracticeRegion(start: 12, end: 20, sourceDuration: 120)
        viewModel.selectRegion(region)
        await waitForCommandCount(2, audio: audio)

        viewModel.clearRegion()
        await waitForCommandCount(3, audio: audio)

        XCTAssertNil(viewModel.region)
        XCTAssertFalse(viewModel.loopEnabled)
        let lastCommand = await audio.commands.last
        XCTAssertEqual(lastCommand, .setLoop(nil))
    }

    @MainActor
    func testPlaybackUsesRegionOnlyWhileLoopIsEnabled() async throws {
        let audio = PracticeAudioClientSpy()
        let viewModel = makeViewModel(audio: audio)
        let region = try PracticeRegion(start: 12, end: 20, sourceDuration: 120)
        viewModel.selectRegion(region)
        await waitForCommandCount(2, audio: audio)

        viewModel.togglePlayback()
        await waitForCommandCount(3, audio: audio)
        for _ in 0 ..< 20 where !viewModel.isPlaying {
            await Task.yield()
        }
        viewModel.setLoopEnabled(false)
        await waitForCommandCount(4, audio: audio)
        viewModel.pause()
        await waitForCommandCount(5, audio: audio)
        viewModel.togglePlayback()
        await waitForCommandCount(6, audio: audio)

        let commands = await audio.commands
        XCTAssertEqual(
            commands[2],
            .playOriginal(region: region, from: 12, rate: 1)
        )
        XCTAssertEqual(commands[3], .setLoop(nil))
        XCTAssertEqual(commands[4], .pause)
        XCTAssertEqual(
            commands[5],
            .playOriginal(region: nil, from: 12, rate: 1)
        )
    }

    @MainActor
    func testSeekOutsideActiveLoopDisablesLoopAndUsesClickedPosition() async throws {
        let audio = PracticeAudioClientSpy()
        let viewModel = makeViewModel(audio: audio)
        let region = try PracticeRegion(start: 12, end: 20, sourceDuration: 120)
        viewModel.selectRegion(region)
        await waitForCommandCount(2, audio: audio)

        viewModel.seek(to: 80)
        await waitForCommandCount(4, audio: audio)

        XCTAssertEqual(viewModel.playhead, 80)
        XCTAssertFalse(viewModel.loopEnabled)
        let commands = await audio.commands
        XCTAssertEqual(Array(commands.suffix(2)), [.setLoop(nil), .seek(80)])
    }

    @MainActor
    func testRateChangeIsOrderedAfterLoopPlaybackRequest() async throws {
        let audio = PracticeAudioClientSpy()
        let viewModel = makeViewModel(audio: audio)
        let region = try PracticeRegion(start: 5, end: 10, sourceDuration: 120)
        viewModel.selectRegion(region)
        viewModel.togglePlayback()
        viewModel.setRate(0.75)
        await waitForCommandCount(4, audio: audio)

        let commands = await audio.commands
        XCTAssertEqual(
            commands,
            [
                .setLoop(region),
                .seek(5),
                .playOriginal(region: region, from: 5, rate: 1),
                .setRate(0.75)
            ]
        )
        XCTAssertEqual(viewModel.rate, 0.75)
    }

    @MainActor
    func testRecordingPhaseLocksFutureTransportIntents() async throws {
        let audio = PracticeAudioClientSpy()
        let viewModel = makeViewModel(audio: audio)
        let initialRegion = try PracticeRegion(start: 5, end: 10, sourceDuration: 120)
        let replacement = try PracticeRegion(start: 20, end: 25, sourceDuration: 120)
        viewModel.selectRegion(initialRegion)
        await waitForCommandCount(2, audio: audio)

        viewModel.setInteractionPhase(.recording)
        viewModel.selectRegion(replacement)
        viewModel.seek(to: 30)
        viewModel.setRate(0.5)
        viewModel.setLoopEnabled(false)
        viewModel.togglePlayback()
        viewModel.setVolume(0.4)
        await waitForCommandCount(3, audio: audio)

        XCTAssertTrue(viewModel.controlsLocked)
        XCTAssertEqual(viewModel.region, initialRegion)
        XCTAssertEqual(viewModel.playhead, 5)
        XCTAssertEqual(viewModel.rate, 1)
        XCTAssertTrue(viewModel.loopEnabled)
        XCTAssertEqual(viewModel.volume, 0.4)
        let lastCommand = await audio.commands.last
        XCTAssertEqual(lastCommand, .setVolume(0.4))
    }

    @MainActor
    private func makeViewModel(audio: PracticeAudioClientSpy) -> PracticeViewModel {
        let prepared = PreparedPractice(
            project: AudioProject(
                id: UUID(),
                sourceDisplayName: "Speech.mp3",
                sourceBookmark: Data([1]),
                duration: 120,
                playhead: 4,
                currentRegion: nil,
                selectedTakeID: nil,
                keptTakeID: nil,
                lastOpenedAt: Date(timeIntervalSince1970: 100)
            ),
            waveform: WaveformPresentation(peaks: [0.2, 0.8, 0.4], warning: nil)
        )
        return PracticeViewModel(
            prepared: prepared,
            audioClient: audio,
            projects: InMemoryProjectRepository(storage: InMemoryPersistence()),
            sessionPreparer: M4SessionPreparer()
        )
    }

    @MainActor
    private func waitForCommandCount(
        _ expectedCount: Int,
        audio: PracticeAudioClientSpy
    ) async {
        for _ in 0 ..< 100 {
            if await audio.commands.count >= expectedCount {
                return
            }
            await Task.yield()
        }
        XCTFail("Expected at least \(expectedCount) audio commands")
    }

    @MainActor
    private func assertCommandCount(
        _ expectedCount: Int,
        audio: PracticeAudioClientSpy
    ) async {
        for _ in 0 ..< 10 {
            await Task.yield()
        }
        let commandCount = await audio.commands.count
        XCTAssertEqual(commandCount, expectedCount)
    }
}

private actor M4SessionPreparer: PracticeSessionPreparing {
    func prepareNewSource(at _: URL) async throws -> PreparedPractice {
        throw M4TestError.unexpectedPreparation
    }

    func prepareExistingProject(id _: UUID) async throws -> PreparedPractice {
        throw M4TestError.unexpectedPreparation
    }

    func relocateProject(id _: UUID, to _: URL) async throws -> PreparedPractice {
        throw M4TestError.unexpectedPreparation
    }

    func endSession() {}
}

private enum M4TestError: Error {
    case unexpectedPreparation
}
