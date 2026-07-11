import Foundation
@testable import Shadowing
import XCTest

struct M9Fixture {
    let viewModel: PracticeViewModel
    let audio: PracticeAudioClientSpy
    let projects: InMemoryProjectRepository
    let takes: InMemoryTakeRepository
    let fileStore: LocalRecordingFileStore
    let committer: RecordingTakeCommitter
    let project: AudioProject
    let region: PracticeRegion
}

enum M9TestSupport {
    static func makeProject(name: String, openedAt: TimeInterval) -> AudioProject {
        AudioProject(
            id: UUID(),
            sourceDisplayName: name,
            sourceBookmark: Data([1]),
            duration: 30,
            playhead: 0,
            currentRegion: nil,
            selectedTakeID: nil,
            keptTakeID: nil,
            lastOpenedAt: Date(timeIntervalSince1970: openedAt)
        )
    }

    static func makeTemporaryRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("Shadowing-M9-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    @MainActor
    static func makeFixture(
        testCase: XCTestCase,
        settings: (any SettingsStore)? = nil,
        countdownSeconds: Int = 0,
        playOriginalWhileRecording: Bool = true,
        scheduler: any ComparisonPlaybackScheduler = ImmediateComparisonPlaybackScheduler()
    ) async throws -> M9Fixture {
        let project = makeProject(name: "Speech.mp3", openedAt: 100)
        let region = try PracticeRegion(start: 4, end: 7, sourceDuration: 30)
        let storage = InMemoryPersistence()
        let projects = InMemoryProjectRepository(storage: storage)
        let takes = InMemoryTakeRepository(storage: storage)
        try await projects.save(project)
        let audio = PracticeAudioClientSpy()
        let permissions = M9MicrophonePermissionServiceFake(status: .authorized)
        let clock = M9ImmediateCountdownClock()
        let root = try makeTemporaryRoot()
        testCase.addTeardownBlock {
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
            sessionPreparer: M9SessionPreparer(),
            recordingDependencies: RecordingDependencies(
                permissions: permissions,
                countdownClock: clock,
                fileStore: fileStore,
                takes: takes,
                committer: committer,
                settings: settings,
                countdownSeconds: countdownSeconds,
                playOriginalWhileRecording: playOriginalWhileRecording,
                now: { Date(timeIntervalSince1970: 200) }
            ),
            comparisonScheduler: scheduler
        )
        viewModel.start()
        viewModel.selectRegion(region)
        await waitForCommand(.seek(region.start), audio: audio)
        return M9Fixture(
            viewModel: viewModel,
            audio: audio,
            projects: projects,
            takes: takes,
            fileStore: fileStore,
            committer: committer,
            project: project,
            region: region
        )
    }

    @MainActor
    static func makeFixtureWithCommittedTake(
        testCase: XCTestCase,
        scheduler: any ComparisonPlaybackScheduler = ImmediateComparisonPlaybackScheduler()
    ) async throws -> M9Fixture {
        let fixture = try await makeFixture(testCase: testCase, scheduler: scheduler)
        fixture.viewModel.startRecording()
        let temporaryURL = await waitForBeginRecording(audio: fixture.audio)
        try Data([1, 2, 3, 4]).write(to: temporaryURL)
        await fixture.audio.emit(.recordingStarted)
        await fixture.audio.emit(
            .recordingFinished(url: temporaryURL, duration: 1.5, reason: .manual)
        )
        await waitUntil { fixture.viewModel.isComparing }
        return fixture
    }

    @MainActor
    static func commitAdditionalTake(
        fixture: M9Fixture,
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
    static func waitUntil(_ condition: @MainActor () -> Bool) async {
        for _ in 0 ..< 200 {
            if condition() {
                return
            }
            await Task.yield()
        }
        XCTFail("Condition was not satisfied")
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
}

actor M9MicrophonePermissionServiceFake: MicrophonePermissionService {
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

actor M9ImmediateCountdownClock: RecordingCountdownClock {
    func waitForNextSecond() async throws {
        await Task.yield()
    }
}

actor M9SessionPreparer: PracticeSessionPreparing {
    func prepareNewSource(at _: URL) async throws -> PreparedPractice {
        throw M9TestError.unexpectedPreparation
    }

    func prepareExistingProject(id _: UUID) async throws -> PreparedPractice {
        throw M9TestError.unexpectedPreparation
    }

    func relocateProject(id _: UUID, to _: URL) async throws -> PreparedPractice {
        throw M9TestError.unexpectedPreparation
    }

    func endSession() {}
}

actor M9FileChooser: AudioFileChoosing {
    func chooseMP3() async -> URL? {
        nil
    }
}

enum M9TestError: Error {
    case unexpectedPreparation
}
