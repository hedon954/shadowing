import Foundation
@testable import Shadowing
import XCTest

final class M3ViewModelTests: XCTestCase {
    @MainActor
    func testFilesViewModelCancelsInFlightLoadWithoutNavigation() async {
        let storage = InMemoryPersistence()
        let preparer = StubSessionPreparer(behavior: .delayed)
        var openedPractice: PreparedPractice?
        let viewModel = FilesViewModel(
            chooser: StubAudioFileChooser(url: nil),
            sessionPreparer: preparer,
            projects: InMemoryProjectRepository(storage: storage)
        ) { prepared in
            openedPractice = prepared
        }

        viewModel.acceptDroppedFile(URL(fileURLWithPath: "/tmp/source.mp3"))
        await Task.yield()
        viewModel.cancelLoading()
        for _ in 0 ..< 10 {
            await Task.yield()
        }

        XCTAssertEqual(viewModel.state, .idle)
        XCTAssertNil(openedPractice)
    }

    @MainActor
    func testFilesViewModelExposesRecoverableImportFailure() async {
        let storage = InMemoryPersistence()
        let viewModel = FilesViewModel(
            chooser: StubAudioFileChooser(url: nil),
            sessionPreparer: StubSessionPreparer(behavior: .failure(.unsupportedFormat)),
            projects: InMemoryProjectRepository(storage: storage)
        ) { _ in
            XCTFail("A failed load must not navigate")
        }

        viewModel.acceptDroppedFile(URL(fileURLWithPath: "/tmp/source.wav"))
        for _ in 0 ..< 20 where viewModel.state.failure == nil {
            await Task.yield()
        }

        XCTAssertEqual(viewModel.state.failure?.action, .chooseAnother)
        XCTAssertEqual(viewModel.state.failure?.recoveryTitle, "Choose Another File")
    }

    @MainActor
    func testPracticeViewModelSendsTransportCommandsAndTracksEvents() async throws {
        let storage = InMemoryPersistence()
        let projects = InMemoryProjectRepository(storage: storage)
        let prepared = makePreparedPractice()
        try await projects.save(prepared.project)
        let audio = PracticeAudioClientSpy()
        let preparer = StubSessionPreparer(behavior: .success(prepared))
        let viewModel = PracticeViewModel(
            prepared: prepared,
            audioClient: audio,
            projects: projects,
            sessionPreparer: preparer
        )

        viewModel.start()
        await waitForCommand(.setVolume(0.8), audio: audio)
        viewModel.togglePlayback()
        await waitForCommand(
            .playOriginal(region: nil, from: 4, rate: 1),
            audio: audio
        )

        var commands = await audio.commands
        XCTAssertTrue(viewModel.isPlaying)

        await audio.emit(.playheadChanged(9))
        for _ in 0 ..< 20 where viewModel.playhead != 9 {
            await Task.yield()
        }
        XCTAssertEqual(viewModel.playhead, 9)

        viewModel.jump(by: -5)
        await waitForCommand(.seek(4), audio: audio)
        viewModel.setRate(1.25)
        await waitForCommand(.setRate(1.25), audio: audio)
        viewModel.setVolume(0.4)
        await waitForCommand(.setVolume(0.4), audio: audio)

        commands = await audio.commands
        XCTAssertTrue(commands.contains(.seek(4)))
        XCTAssertTrue(commands.contains(.setRate(1.25)))
        XCTAssertTrue(commands.contains(.setVolume(0.4)))

        await viewModel.close()
        let endCount = await preparer.endCount
        let savedProject = try await projects.project(id: prepared.project.id)
        XCTAssertEqual(endCount, 1)
        XCTAssertEqual(savedProject?.playhead, 4)
    }

    @MainActor
    func testPracticeViewModelSurfacesPlaybackFailure() async {
        let prepared = makePreparedPractice()
        let viewModel = PracticeViewModel(
            prepared: prepared,
            audioClient: FailingPracticeAudioClient(),
            projects: InMemoryProjectRepository(storage: InMemoryPersistence()),
            sessionPreparer: StubSessionPreparer(behavior: .success(prepared))
        )

        viewModel.togglePlayback()
        for _ in 0 ..< 20 where viewModel.failure == nil {
            await Task.yield()
        }

        XCTAssertEqual(viewModel.failure?.message, StubM3ViewModelError.failed.localizedDescription)
        XCTAssertFalse(viewModel.isPlaying)
    }

    @MainActor
    private func waitForCommand(
        _ expected: PracticeAudioCommand,
        audio: PracticeAudioClientSpy
    ) async {
        for _ in 0 ..< 100 {
            if await audio.commands.contains(expected) {
                return
            }
            await Task.yield()
        }
        XCTFail("Expected command \(expected)")
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

    private func makePreparedPractice() -> PreparedPractice {
        PreparedPractice(
            project: AudioProject(
                id: UUID(),
                sourceDisplayName: "The Power of Habit.mp3",
                sourceBookmark: Data([1]),
                duration: 60,
                playhead: 4,
                currentRegion: nil,
                selectedTakeID: nil,
                keptTakeID: nil,
                lastOpenedAt: Date(timeIntervalSince1970: 100)
            ),
            waveform: WaveformPresentation(peaks: [0.2, 0.8, 0.4], warning: nil)
        )
    }
}

private struct StubAudioFileChooser: AudioFileChoosing {
    let url: URL?

    @MainActor
    func chooseMP3() async -> URL? {
        url
    }
}

private actor StubSessionPreparer: PracticeSessionPreparing {
    enum Behavior: Sendable {
        case delayed
        case failure(AudioSourceError)
        case success(PreparedPractice)
    }

    private let behavior: Behavior
    private(set) var endCount = 0

    init(behavior: Behavior) {
        self.behavior = behavior
    }

    func prepareNewSource(at _: URL) async throws -> PreparedPractice {
        try await result()
    }

    func prepareExistingProject(id _: UUID) async throws -> PreparedPractice {
        try await result()
    }

    func relocateProject(id _: UUID, to _: URL) async throws -> PreparedPractice {
        try await result()
    }

    func endSession() {
        endCount += 1
    }

    private func result() async throws -> PreparedPractice {
        switch behavior {
        case .delayed:
            try await Task.sleep(for: .seconds(30))
            throw CancellationError()
        case let .failure(error):
            throw error
        case let .success(prepared):
            return prepared
        }
    }
}

private actor FailingPracticeAudioClient: PracticeAudioClient {
    func execute(_: PracticeAudioCommand) async throws {
        throw StubM3ViewModelError.failed
    }

    func eventStream() async -> AsyncStream<PracticeAudioEvent> {
        AsyncStream { continuation in
            continuation.finish()
        }
    }
}

private enum StubM3ViewModelError: Error, LocalizedError {
    case failed

    var errorDescription: String? {
        "Playback failed."
    }
}
