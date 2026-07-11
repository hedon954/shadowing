import Foundation
@testable import Shadowing
import XCTest

@MainActor
final class M6ViewModelTests: XCTestCase {
    func testComparisonModeSwitchResetsPlayhead() async throws {
        let fixture = try await makeFixtureWithCommittedTake()

        XCTAssertEqual(fixture.viewModel.comparisonMode, .selectedTake)
        XCTAssertEqual(fixture.viewModel.playhead, 0)

        fixture.viewModel.setComparisonMode(.original)
        XCTAssertEqual(fixture.viewModel.comparisonMode, .original)
        XCTAssertEqual(fixture.viewModel.playhead, fixture.region.start)

        fixture.viewModel.setComparisonMode(.selectedTake)
        XCTAssertEqual(fixture.viewModel.comparisonMode, .selectedTake)
        XCTAssertEqual(fixture.viewModel.playhead, 0)
    }

    func testSelectTakeSwitchesActiveTakeWithoutOverwritingOthers() async throws {
        let fixture = try await makeFixtureWithCommittedTake()
        let first = try XCTUnwrap(fixture.viewModel.activeTake)
        let secondRegion = try PracticeRegion(start: 10, end: 13, sourceDuration: 30)
        let second = try await commitAdditionalTake(
            fixture: fixture,
            region: secondRegion,
            sequence: 2,
            createdAt: Date(timeIntervalSince1970: 300)
        )

        await fixture.viewModel.enterComparison(with: second)
        fixture.viewModel.selectTake(first)

        XCTAssertEqual(fixture.viewModel.activeTake?.id, first.id)
        XCTAssertEqual(fixture.viewModel.takes.count, 2)
        XCTAssertEqual(
            Set(fixture.viewModel.takes.map(\.id)),
            Set([first.id, second.id])
        )
        XCTAssertNotNil(fixture.viewModel.comparisonRegionNotice)
    }

    func testDeleteCurrentTakeSelectsMostRecentRemaining() async throws {
        let fixture = try await makeFixtureWithCommittedTake()
        let first = try XCTUnwrap(fixture.viewModel.activeTake)
        let second = try await commitAdditionalTake(
            fixture: fixture,
            region: fixture.region,
            sequence: 2,
            createdAt: Date(timeIntervalSince1970: 400)
        )
        await fixture.viewModel.refreshTakes()
        fixture.viewModel.selectTake(second)

        fixture.viewModel.requestDeleteTake(second)
        fixture.viewModel.confirmDeleteTake()
        await waitUntil {
            fixture.viewModel.activeTake?.id == first.id
        }

        XCTAssertEqual(fixture.viewModel.takes.map(\.id), [first.id])
        XCTAssertEqual(fixture.viewModel.activeTake?.id, first.id)
        if case let .comparisonReady(take) = fixture.viewModel.recordingPresentation {
            XCTAssertEqual(take.id, first.id)
        } else {
            XCTFail("Expected comparisonReady after deleting one of two takes")
        }
    }

    func testDeleteLastTakeReturnsToPractice() async throws {
        let fixture = try await makeFixtureWithCommittedTake()
        let take = try XCTUnwrap(fixture.viewModel.activeTake)

        fixture.viewModel.requestDeleteTake(take)
        fixture.viewModel.confirmDeleteTake()
        await waitUntil {
            fixture.viewModel.recordingPresentation == .idle
        }

        XCTAssertTrue(fixture.viewModel.takes.isEmpty)
        XCTAssertNil(fixture.viewModel.activeTake)
        XCTAssertNil(fixture.viewModel.project.selectedTakeID)
        XCTAssertFalse(fixture.viewModel.isComparing)
    }

    func testRerecordKeepsExistingTakesAndStartsNewRecording() async throws {
        let fixture = try await makeFixtureWithCommittedTake()
        let existing = try XCTUnwrap(fixture.viewModel.activeTake)
        let commandCountBefore = await fixture.audio.commands.count

        fixture.viewModel.rerecord()
        let temporaryURL = await waitForBeginRecording(
            audio: fixture.audio,
            afterCommandCount: commandCountBefore
        )

        XCTAssertEqual(fixture.viewModel.takes.map(\.id), [existing.id])
        XCTAssertFalse(temporaryURL.lastPathComponent.hasPrefix(existing.id.uuidString))
        let commands = await fixture.audio.commands
        XCTAssertTrue(commands.suffix(from: commandCountBefore).contains { command in
            if case .beginRecording = command {
                return true
            }
            return false
        })
    }

    func testPlayCommandsFollowComparisonMode() async throws {
        let fixture = try await makeFixtureWithCommittedTake()
        let take = try XCTUnwrap(fixture.viewModel.activeTake)

        fixture.viewModel.toggleComparisonPlayback()
        await waitForCommand(
            .playTake(takeID: take.id, from: 0),
            audio: fixture.audio
        )

        fixture.viewModel.setComparisonMode(.original)
        await waitUntil {
            fixture.viewModel.comparisonMode == .original
                && fixture.viewModel.isPlaying == false
        }
        fixture.viewModel.toggleComparisonPlayback()
        await waitForCommand(
            .playOriginal(region: take.region, from: take.region.start, rate: 1),
            audio: fixture.audio
        )
    }

    func testChangingPracticeRegionDoesNotMutateTakeSnapshot() async throws {
        let fixture = try await makeFixtureWithCommittedTake()
        let take = try XCTUnwrap(fixture.viewModel.activeTake)
        let newRegion = try PracticeRegion(start: 8, end: 12, sourceDuration: 30)

        fixture.viewModel.selectRegion(newRegion)

        let stored = try await fixture.takes.take(id: take.id)
        XCTAssertEqual(stored?.region, fixture.region)
        XCTAssertEqual(fixture.viewModel.activeTake?.region, fixture.region)
    }

    private func makeFixtureWithCommittedTake() async throws -> M6Fixture {
        let fixture = try await makeFixture()
        fixture.viewModel.startRecording()
        let temporaryURL = await waitForBeginRecording(audio: fixture.audio)
        try Data([1, 2, 3, 4]).write(to: temporaryURL)
        await fixture.audio.emit(.recordingStarted)
        await fixture.audio.emit(
            .recordingFinished(
                url: temporaryURL,
                duration: 1.5,
                reason: .manual
            )
        )
        await waitUntil {
            fixture.viewModel.isComparing
        }
        return fixture
    }

    private func commitAdditionalTake(
        fixture: M6Fixture,
        region: PracticeRegion,
        sequence: Int,
        createdAt: Date
    ) async throws -> Take {
        let draft = try TakeDraft(
            projectID: fixture.project.id,
            region: region,
            sequence: sequence,
            duration: region.duration,
            createdAt: createdAt
        )
        let temporaryURL = try fixture.fileStore.temporaryTakeURL(id: draft.id)
        try Data([9, 9, 9]).write(to: temporaryURL)
        return try await fixture.committer.commit(draft, temporaryFile: temporaryURL)
    }

    private func makeFixture() async throws -> M6Fixture {
        let project = makeProject()
        let region = try PracticeRegion(start: 4, end: 7, sourceDuration: 30)
        let storage = InMemoryPersistence()
        let projects = InMemoryProjectRepository(storage: storage)
        let takes = InMemoryTakeRepository(storage: storage)
        try await projects.save(project)
        let audio = PracticeAudioClientSpy()
        let permissions = M6MicrophonePermissionServiceFake(status: .authorized)
        let clock = M6ImmediateCountdownClock()
        let root = try makeTemporaryRoot()
        addTeardownBlock {
            try FileManager.default.removeItem(at: root)
        }
        let fileStore = LocalRecordingFileStore(rootDirectory: root)
        let committer = RecordingTakeCommitter(
            fileStore: fileStore,
            takeRepository: takes,
            validator: AlwaysPlayableRecordingValidator()
        )
        let viewModel = PracticeViewModel(
            prepared: PreparedPractice(
                project: project,
                waveform: WaveformPresentation(
                    peaks: Array(repeating: 0.5, count: 64),
                    warning: nil
                )
            ),
            audioClient: audio,
            projects: projects,
            sessionPreparer: M6SessionPreparer(),
            recordingDependencies: RecordingDependencies(
                permissions: permissions,
                countdownClock: clock,
                fileStore: fileStore,
                takes: takes,
                committer: committer,
                countdownSeconds: 0,
                now: { Date(timeIntervalSince1970: 200) }
            )
        )
        viewModel.start()
        viewModel.selectRegion(region)
        await waitForCommand(.seek(region.start), audio: audio)
        return M6Fixture(
            viewModel: viewModel,
            audio: audio,
            takes: takes,
            fileStore: fileStore,
            committer: committer,
            project: project,
            region: region
        )
    }

    private func makeProject() -> AudioProject {
        AudioProject(
            id: UUID(),
            sourceDisplayName: "Speech.mp3",
            sourceBookmark: Data([1]),
            duration: 30,
            playhead: 0,
            currentRegion: nil,
            selectedTakeID: nil,
            keptTakeID: nil,
            lastOpenedAt: Date(timeIntervalSince1970: 100)
        )
    }

    private func makeTemporaryRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("Shadowing-M6-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        return root
    }

    private func waitForBeginRecording(
        audio: PracticeAudioClientSpy,
        afterCommandCount: Int = 0
    ) async -> URL {
        for _ in 0 ..< 200 {
            let commands = await audio.commands
            for command in commands.suffix(from: min(afterCommandCount, commands.count)) {
                if case let .beginRecording(_, url, _) = command {
                    return url
                }
            }
            await Task.yield()
        }
        XCTFail("Expected beginRecording command")
        return URL(fileURLWithPath: "/missing")
    }

    private func waitForCommand(
        _ expected: PracticeAudioCommand,
        audio: PracticeAudioClientSpy
    ) async {
        for _ in 0 ..< 200 {
            if await audio.commands.contains(expected) {
                return
            }
            await Task.yield()
        }
        XCTFail("Expected command \(expected)")
    }

    private func waitUntil(_ condition: @MainActor () -> Bool) async {
        for _ in 0 ..< 200 {
            if condition() {
                return
            }
            await Task.yield()
        }
        XCTFail("Condition was not satisfied")
    }
}

private struct M6Fixture {
    let viewModel: PracticeViewModel
    let audio: PracticeAudioClientSpy
    let takes: InMemoryTakeRepository
    let fileStore: LocalRecordingFileStore
    let committer: RecordingTakeCommitter
    let project: AudioProject
    let region: PracticeRegion
}

private actor M6MicrophonePermissionServiceFake: MicrophonePermissionService {
    private let status: MicrophonePermissionState

    init(status: MicrophonePermissionState) {
        self.status = status
    }

    func authorizationStatus() -> MicrophonePermissionState {
        status
    }

    func requestAuthorization() -> MicrophonePermissionState {
        status
    }

    func openSystemSettings() {}
}

private actor M6ImmediateCountdownClock: RecordingCountdownClock {
    func waitForNextSecond() async throws {
        await Task.yield()
    }
}

private actor M6SessionPreparer: PracticeSessionPreparing {
    func prepareNewSource(at _: URL) async throws -> PreparedPractice {
        throw M6TestError.unexpectedPreparation
    }

    func prepareExistingProject(id _: UUID) async throws -> PreparedPractice {
        throw M6TestError.unexpectedPreparation
    }

    func relocateProject(id _: UUID, to _: URL) async throws -> PreparedPractice {
        throw M6TestError.unexpectedPreparation
    }

    func endSession() {}
}

private enum M6TestError: Error {
    case unexpectedPreparation
}
