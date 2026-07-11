import Foundation
@testable import Shadowing
import XCTest

struct M6Fixture {
    let viewModel: PracticeViewModel
    let audio: PracticeAudioClientSpy
    let takes: InMemoryTakeRepository
    let fileStore: LocalRecordingFileStore
    let committer: RecordingTakeCommitter
    let project: AudioProject
    let region: PracticeRegion
}

enum M6TestSupport {
    @MainActor
    static func makeFixture() async throws -> (fixture: M6Fixture, temporaryRoot: URL) {
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
        let fixture = M6Fixture(
            viewModel: viewModel,
            audio: audio,
            takes: takes,
            fileStore: fileStore,
            committer: committer,
            project: project,
            region: region
        )
        return (fixture, root)
    }

    @MainActor
    static func makeFixtureWithCommittedTake() async throws -> (fixture: M6Fixture, temporaryRoot: URL) {
        let pair = try await makeFixture()
        let fixture = pair.fixture
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
                && fixture.viewModel.recordingPresentation == .idle
        }
        return pair
    }

    static func makeProject() -> AudioProject {
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

    static func makeTemporaryRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("Shadowing-M6-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        return root
    }

    static func waitForBeginRecording(
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

    static func waitForCommand(
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

    @MainActor
    static func waitUntilAsync(_ condition: @MainActor () async -> Bool) async {
        for _ in 0 ..< 200 {
            if await condition() {
                return
            }
            await Task.yield()
        }
        XCTFail("Condition was not satisfied")
    }

    @MainActor
    static func waitUntil(_ condition: @MainActor () -> Bool) async {
        for _ in 0 ..< 200 {
            if condition() {
                return
            }
            await Task.yield()
        }
        XCTFail("Condition was not satisfied")
    }
}

actor M6MicrophonePermissionServiceFake: MicrophonePermissionService {
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

actor M6ImmediateCountdownClock: RecordingCountdownClock {
    func waitForNextSecond() async throws {
        await Task.yield()
    }
}

actor M6SessionPreparer: PracticeSessionPreparing {
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

enum M6TestError: Error {
    case unexpectedPreparation
}
