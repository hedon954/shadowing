import Foundation
@testable import Shadowing
import XCTest

enum M7TestSupport {
    @MainActor
    static func makeHydrateFixture(testCase: XCTestCase) async throws -> M7HydrateFixture {
        let storage = InMemoryPersistence()
        let projects = InMemoryProjectRepository(storage: storage)
        let takes = InMemoryTakeRepository(storage: storage)
        let region = try PracticeRegion(start: 3, end: 8, sourceDuration: 60)
        let projectID = UUID()
        let take = try Take(
            id: UUID(),
            projectID: projectID,
            region: region,
            sequence: 1,
            relativeAudioPath: "projects/\(projectID.uuidString)/take.caf",
            duration: 5,
            createdAt: Date(timeIntervalSince1970: 50)
        )
        let project = AudioProject(
            id: projectID,
            sourceDisplayName: "Speech.mp3",
            sourceBookmark: Data([7]),
            duration: 60,
            playhead: 12,
            currentRegion: region,
            selectedTakeID: take.id,
            keptTakeID: nil,
            lastOpenedAt: Date(timeIntervalSince1970: 100),
            playbackRate: 0.75
        )
        try await projects.save(project)
        try await takes.save(take)

        let root = try makeTemporaryRoot(testCase: testCase)
        let fileStore = LocalRecordingFileStore(rootDirectory: root)
        let viewModel = PracticeViewModel(
            prepared: PreparedPractice(
                project: project,
                waveform: WaveformPresentation(peaks: [0.2, 0.5, 0.8], warning: nil)
            ),
            audioClient: PracticeAudioClientSpy(),
            projects: projects,
            sessionPreparer: M7SessionPreparer(),
            recordingDependencies: RecordingDependencies(
                permissions: M7MicrophonePermissionServiceFake(status: .authorized),
                countdownClock: M7ImmediateCountdownClock(),
                fileStore: fileStore,
                takes: takes,
                committer: RecordingTakeCommitter(
                    fileStore: fileStore,
                    takeRepository: takes,
                    validator: AlwaysPlayableRecordingValidator()
                ),
                countdownSeconds: 0
            )
        )
        return M7HydrateFixture(
            viewModel: viewModel,
            projects: projects,
            projectID: projectID,
            take: take,
            region: region
        )
    }

    @MainActor
    static func makeRecordingFixture(testCase: XCTestCase) async throws -> M7RecordingFixture {
        let storage = InMemoryPersistence()
        let projects = InMemoryProjectRepository(storage: storage)
        let takes = InMemoryTakeRepository(storage: storage)
        let region = try PracticeRegion(start: 1, end: 4, sourceDuration: 30)
        let project = AudioProject(
            id: UUID(),
            sourceDisplayName: "Speech.mp3",
            sourceBookmark: Data([1]),
            duration: 30,
            playhead: 0,
            currentRegion: region,
            selectedTakeID: nil,
            keptTakeID: nil,
            lastOpenedAt: Date(timeIntervalSince1970: 100)
        )
        try await projects.save(project)
        let root = try makeTemporaryRoot(testCase: testCase)
        let fileStore = LocalRecordingFileStore(rootDirectory: root)
        let audio = PracticeAudioClientSpy()
        let viewModel = PracticeViewModel(
            prepared: PreparedPractice(
                project: project,
                waveform: WaveformPresentation(peaks: Array(repeating: 0.4, count: 32), warning: nil)
            ),
            audioClient: audio,
            projects: projects,
            sessionPreparer: M7SessionPreparer(),
            recordingDependencies: RecordingDependencies(
                permissions: M7MicrophonePermissionServiceFake(status: .authorized),
                countdownClock: M7ImmediateCountdownClock(),
                fileStore: fileStore,
                takes: takes,
                committer: RecordingTakeCommitter(
                    fileStore: fileStore,
                    takeRepository: takes,
                    validator: AlwaysPlayableRecordingValidator()
                ),
                countdownSeconds: 0
            )
        )
        viewModel.start()
        viewModel.selectRegion(region)
        await waitForCommand(.seek(region.start), audio: audio)
        return M7RecordingFixture(
            viewModel: viewModel,
            audio: audio,
            takes: takes,
            project: project
        )
    }

    static func makePreparedPractice(playhead: TimeInterval) -> PreparedPractice {
        PreparedPractice(
            project: AudioProject(
                id: UUID(),
                sourceDisplayName: "Speech.mp3",
                sourceBookmark: Data([1]),
                duration: 60,
                playhead: playhead,
                currentRegion: nil,
                selectedTakeID: nil,
                keptTakeID: nil,
                lastOpenedAt: Date(timeIntervalSince1970: 100)
            ),
            waveform: WaveformPresentation(peaks: [0.2, 0.8], warning: nil)
        )
    }

    static func makeTemporaryRoot(testCase: XCTestCase) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("Shadowing-M7-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        testCase.addTeardownBlock {
            try? FileManager.default.removeItem(at: root)
        }
        return root
    }

    static func waitForBeginRecording(audio: PracticeAudioClientSpy) async -> URL {
        for _ in 0 ..< 200 {
            let commands = await audio.commands
            for command in commands {
                if case let .beginRecording(_, url, _) = command {
                    return url
                }
            }
            await Task.yield()
        }
        XCTFail("Expected beginRecording")
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
        XCTFail("Expected \(expected)")
    }

    @MainActor
    static func waitUntil(_ condition: @MainActor () async -> Bool) async {
        for _ in 0 ..< 200 {
            if await condition() {
                return
            }
            await Task.yield()
        }
        XCTFail("Condition was not satisfied")
    }
}

struct M7HydrateFixture {
    let viewModel: PracticeViewModel
    let projects: InMemoryProjectRepository
    let projectID: UUID
    let take: Take
    let region: PracticeRegion
}

struct M7RecordingFixture {
    let viewModel: PracticeViewModel
    let audio: PracticeAudioClientSpy
    let takes: InMemoryTakeRepository
    let project: AudioProject
}

actor M7SessionPreparer: PracticeSessionPreparing {
    func prepareNewSource(at _: URL) async throws -> PreparedPractice {
        throw M7TestError.unexpected
    }

    func prepareExistingProject(id _: UUID) async throws -> PreparedPractice {
        throw M7TestError.unexpected
    }

    func relocateProject(id _: UUID, to _: URL) async throws -> PreparedPractice {
        throw M7TestError.unexpected
    }

    func endSession() {}
}

actor M7MicrophonePermissionServiceFake: MicrophonePermissionService {
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

actor M7ImmediateCountdownClock: RecordingCountdownClock {
    func waitForNextSecond() async throws {
        await Task.yield()
    }
}

enum M7TestError: Error {
    case unexpected
}
