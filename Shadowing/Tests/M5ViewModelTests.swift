import Foundation
@testable import Shadowing
import XCTest

@MainActor
final class M5ViewModelTests: XCTestCase {
    func testNotDeterminedPermissionRequestsAccessAndRunsThreeSecondCountdown() async throws {
        let fixture = try await makeFixture(
            permission: .notDetermined,
            requestedPermission: .authorized
        )

        fixture.viewModel.startRecording()
        _ = await waitForBeginRecording(audio: fixture.audio)

        let requestCount = await fixture.permissions.requestCount
        let tickCount = await fixture.clock.tickCount
        XCTAssertEqual(requestCount, 1)
        XCTAssertEqual(tickCount, 3)
        let commands = await fixture.audio.commands
        guard commands.count >= 4 else {
            return XCTFail("Expected region setup and recording commands")
        }
        XCTAssertEqual(commands[commands.count - 2], .seek(fixture.region.start))
        guard case let .beginRecording(region, _, playOriginal) = commands.last else {
            return XCTFail("Expected beginRecording command")
        }
        XCTAssertEqual(region.start, fixture.region.start, accuracy: 0.001)
        XCTAssertEqual(region.end, fixture.project.duration, accuracy: 0.001)
        XCTAssertFalse(playOriginal)
    }

    func testDeniedAndRestrictedPermissionShowRecoveryPrompt() async throws {
        for permission in [MicrophonePermissionState.denied, .restricted] {
            let fixture = try await makeFixture(permission: permission)

            fixture.viewModel.startRecording()
            await waitUntil {
                fixture.viewModel.microphonePermissionPrompt == permission
            }

            XCTAssertEqual(fixture.viewModel.recordingPresentation, .idle)
            XCTAssertFalse(fixture.viewModel.controlsLocked)
            fixture.viewModel.openMicrophoneSettings()
            await waitForOpenSettings(permissions: fixture.permissions)
            let commands = await fixture.audio.commands
            XCTAssertFalse(commands.contains { command in
                if case .beginRecording = command {
                    return true
                }
                return false
            })
        }
    }

    func testManualStopCommitsTakeAndEntersComparisonReadyState() async throws {
        let fixture = try await makeFixture(
            permission: .authorized,
            countdownSeconds: 0
        )
        fixture.viewModel.startRecording()
        let temporaryURL = await waitForBeginRecording(audio: fixture.audio)
        try Data([1, 2, 3]).write(to: temporaryURL)
        await fixture.audio.emit(.recordingStarted)
        await waitUntil {
            fixture.viewModel.recordingPresentation == .recording(elapsed: 0)
        }

        fixture.viewModel.stopRecording()
        await waitForCommand(.stopRecording, audio: fixture.audio)
        await fixture.audio.emit(
            .recordingFinished(
                url: temporaryURL,
                duration: 1.4,
                reason: .manual
            )
        )
        await waitUntil {
            fixture.viewModel.recordingPresentation == .idle
                && fixture.viewModel.activeTake != nil
        }

        XCTAssertEqual(fixture.viewModel.lastRecordingStopReason, .manual)
        let takes = try await fixture.takes.takes(projectID: fixture.project.id)
        XCTAssertEqual(takes.count, 1)
        XCTAssertEqual(fixture.viewModel.activeTake, takes.first)
        XCTAssertEqual(fixture.viewModel.project.selectedTakeID, takes.first?.id)
        XCTAssertTrue(fixture.viewModel.showsMultiTrackWorkspace)
    }

    func testRegionEndAndInputRemovalStopReasonsArePreserved() async throws {
        for reason in [RecordingStopReason.regionEnd, .inputDeviceRemoved] {
            let fixture = try await makeFixture(
                permission: .authorized,
                countdownSeconds: 0
            )
            fixture.viewModel.startRecording()
            let temporaryURL = await waitForBeginRecording(audio: fixture.audio)
            try Data([1]).write(to: temporaryURL)
            await fixture.audio.emit(.recordingStarted)
            await fixture.audio.emit(
                .recordingFinished(
                    url: temporaryURL,
                    duration: 1,
                    reason: reason
                )
            )
            await waitUntil {
                fixture.viewModel.recordingPresentation == .idle
                    && fixture.viewModel.activeTake != nil
            }

            XCTAssertEqual(fixture.viewModel.lastRecordingStopReason, reason)
        }
    }

    func testTooShortRecordingIsDiscardedWithoutCreatingTake() async throws {
        let fixture = try await makeFixture(
            permission: .authorized,
            countdownSeconds: 0
        )
        fixture.viewModel.startRecording()
        let temporaryURL = await waitForBeginRecording(audio: fixture.audio)
        try Data([1]).write(to: temporaryURL)
        await fixture.audio.emit(.recordingStarted)
        await fixture.audio.emit(
            .recordingFinished(
                url: temporaryURL,
                duration: 0.2,
                reason: .manual
            )
        )
        await waitUntil {
            fixture.viewModel.failure != nil
        }

        XCTAssertEqual(fixture.viewModel.recordingPresentation, .idle)
        XCTAssertTrue(
            fixture.viewModel.failure?.message.contains("record again") == true
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: temporaryURL.path))
        let takes = try await fixture.takes.takes(projectID: fixture.project.id)
        XCTAssertTrue(takes.isEmpty)
    }

    func testRecordingWriteFailureStopsAndRemovesTemporaryFile() async throws {
        let fixture = try await makeFixture(
            permission: .authorized,
            countdownSeconds: 0
        )
        fixture.viewModel.startRecording()
        let temporaryURL = await waitForBeginRecording(audio: fixture.audio)
        try Data([1]).write(to: temporaryURL)
        await fixture.audio.emit(.recordingStarted)
        await fixture.audio.emit(
            .failed(
                PracticeAudioFailure(
                    operation: .recording,
                    message: "Disk is full."
                )
            )
        )
        await waitUntil {
            fixture.viewModel.lastRecordingStopReason == .writeFailure
        }

        XCTAssertEqual(fixture.viewModel.recordingPresentation, .idle)
        XCTAssertFalse(FileManager.default.fileExists(atPath: temporaryURL.path))
        XCTAssertEqual(fixture.viewModel.failure?.message, "Disk is full.")
    }

    func testLivePeaksRemainBounded() async throws {
        let fixture = try await makeFixture(
            permission: .authorized,
            countdownSeconds: 0
        )
        fixture.viewModel.startRecording()
        _ = await waitForBeginRecording(audio: fixture.audio)
        await fixture.audio.emit(.recordingStarted)
        for _ in 0 ..< 50 {
            await fixture.audio.emit(
                .recordingEnvelope(
                    (0 ..< 10).map { index in
                        TimedWaveformEnvelopePoint(
                            time: Double(index) / 100,
                            envelope: WaveformEnvelopePoint(amplitude: 0.8)
                        )
                    }
                )
            )
        }
        await waitUntil {
            fixture.viewModel.liveRecordingPeaks.count
                == PracticeViewModel.maximumLivePeakCount
        }

        XCTAssertEqual(
            fixture.viewModel.liveRecordingPeaks.count,
            PracticeViewModel.maximumLivePeakCount
        )
    }

    func testNoMicrophoneAudioEndsTheTakeWithTryAgainAndSavesNothing() async throws {
        let fixture = try await makeFixture(permission: .authorized, countdownSeconds: 0)
        fixture.viewModel.startRecording()
        let temporaryURL = await waitForBeginRecording(audio: fixture.audio)
        try Data([1]).write(to: temporaryURL)
        await fixture.audio.emit(.recordingStarted)
        await fixture.audio.emit(.recordingNoAudio)
        await waitUntil {
            fixture.viewModel.recordingIssue == .noMicrophoneAudio
        }

        XCTAssertEqual(fixture.viewModel.recordingPresentation, .idle)
        XCTAssertFalse(fixture.viewModel.controlsLocked)
        XCTAssertNil(fixture.viewModel.failure)
        XCTAssertFalse(FileManager.default.fileExists(atPath: temporaryURL.path))
        let takes = try await fixture.takes.takes(projectID: fixture.project.id)
        XCTAssertTrue(takes.isEmpty)

        let beginCount = await fixture.audio.commands.filter(\.isBeginRecording).count
        fixture.viewModel.retryAfterRecordingIssue()
        XCTAssertNil(fixture.viewModel.recordingIssue)
        for _ in 0 ..< 200 where await fixture.audio.commands.filter(\.isBeginRecording).count == beginCount {
            await Task.yield()
        }
        let retriedCount = await fixture.audio.commands.filter(\.isBeginRecording).count
        XCTAssertEqual(retriedCount, beginCount + 1, "Try Again starts a new take")
    }

    func testOnlyAnActiveRecordingShowsRecordingLabels() async throws {
        let fixture = try await makeFixture(permission: .authorized, countdownSeconds: 0)
        let cases: [(RecordingPresentation, Bool)] = [
            (.checkingPermission, false),
            (.countingDown(remainingSeconds: 2), false),
            (.recording(elapsed: 1), true),
            (.finalizing, false)
        ]
        for (presentation, recording) in cases {
            fixture.viewModel.recordingPresentation = presentation
            XCTAssertEqual(fixture.viewModel.isCapturingAudio, recording, "\(presentation)")
            XCTAssertEqual(fixture.viewModel.showsRecordingBadge, recording, "\(presentation)")
        }
    }

    func testSavingThatNeverFinishesRestoresTheControls() async throws {
        let fixture = try await makeFixture(permission: .authorized, countdownSeconds: 0)
        fixture.viewModel.savingTimeout = .milliseconds(50)
        fixture.viewModel.startRecording()
        _ = await waitForBeginRecording(audio: fixture.audio)
        await fixture.audio.emit(.recordingStarted)
        await waitUntil {
            fixture.viewModel.recordingPresentation == .recording(elapsed: 0)
        }
        XCTAssertTrue(fixture.viewModel.showsRecordingBadge)

        fixture.viewModel.stopRecording()
        XCTAssertFalse(fixture.viewModel.showsRecordingBadge, "only \"Saving recording…\" shows while saving")
        // The engine never reports the finished take.
        let deadline = ContinuousClock.now + .seconds(3)
        while fixture.viewModel.failure == nil, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }

        XCTAssertEqual(fixture.viewModel.failure?.message, PracticeRecordingError.savingTimedOut.errorDescription)
        XCTAssertEqual(fixture.viewModel.recordingPresentation, .idle)
        XCTAssertFalse(fixture.viewModel.controlsLocked)
        let takes = try await fixture.takes.takes(projectID: fixture.project.id)
        XCTAssertTrue(takes.isEmpty)
    }
}

private extension M5ViewModelTests {
    func makeFixture(
        permission: MicrophonePermissionState,
        requestedPermission: MicrophonePermissionState? = nil,
        countdownSeconds: Int = 3
    ) async throws -> M5Fixture {
        let project = makeProject()
        let region = try PracticeRegion(start: 4, end: 7, sourceDuration: 30)
        let storage = InMemoryPersistence()
        let projects = InMemoryProjectRepository(storage: storage)
        let takes = InMemoryTakeRepository(storage: storage)
        try await projects.save(project)
        let audio = PracticeAudioClientSpy()
        let permissions = MicrophonePermissionServiceFake(
            status: permission,
            requestedStatus: requestedPermission ?? permission
        )
        let clock = ImmediateRecordingCountdownClock()
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
                    peaks: [0.2, 0.8, 0.4],
                    warning: nil
                )
            ),
            audioClient: audio,
            projects: projects,
            sessionPreparer: M5SessionPreparer(),
            recordingDependencies: RecordingDependencies(
                permissions: permissions,
                countdownClock: clock,
                fileStore: fileStore,
                takes: takes,
                committer: committer,
                trash: .temporaryFolder(),
                countdownSeconds: countdownSeconds,
                now: { Date(timeIntervalSince1970: 200) }
            )
        )
        viewModel.start()
        viewModel.selectRegion(region)
        await waitForCommand(.seek(region.start), audio: audio)
        return M5Fixture(
            viewModel: viewModel,
            audio: audio,
            permissions: permissions,
            clock: clock,
            takes: takes,
            project: project,
            region: region
        )
    }

    func makeProject() -> AudioProject {
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

    func makeTemporaryRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("Shadowing-M5-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        return root
    }

    func waitForBeginRecording(
        audio: PracticeAudioClientSpy
    ) async -> URL {
        for _ in 0 ..< 200 {
            for command in await audio.commands {
                if case let .beginRecording(_, url, _) = command {
                    return url
                }
            }
            await Task.yield()
        }
        XCTFail("Expected beginRecording command")
        return URL(fileURLWithPath: "/missing")
    }

    func waitForCommand(
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

    func waitUntil(_ condition: @MainActor () -> Bool) async {
        for _ in 0 ..< 200 {
            if condition() {
                return
            }
            await Task.yield()
        }
        XCTFail("Condition was not satisfied")
    }
}

private func waitForOpenSettings(
    permissions: MicrophonePermissionServiceFake
) async {
    for _ in 0 ..< 200 {
        if await permissions.openSettingsCount == 1 {
            return
        }
        await Task.yield()
    }
    XCTFail("Expected System Settings to open")
}

private struct M5Fixture {
    let viewModel: PracticeViewModel
    let audio: PracticeAudioClientSpy
    let permissions: MicrophonePermissionServiceFake
    let clock: ImmediateRecordingCountdownClock
    let takes: InMemoryTakeRepository
    let project: AudioProject
    let region: PracticeRegion
}

private actor MicrophonePermissionServiceFake: MicrophonePermissionService {
    private let status: MicrophonePermissionState
    private let requestedStatus: MicrophonePermissionState
    private(set) var requestCount = 0
    private(set) var openSettingsCount = 0

    init(
        status: MicrophonePermissionState,
        requestedStatus: MicrophonePermissionState
    ) {
        self.status = status
        self.requestedStatus = requestedStatus
    }

    func authorizationStatus() -> MicrophonePermissionState {
        status
    }

    func requestAuthorization() -> MicrophonePermissionState {
        requestCount += 1
        return requestedStatus
    }

    func openSystemSettings() {
        openSettingsCount += 1
    }
}

private actor ImmediateRecordingCountdownClock: RecordingCountdownClock {
    private(set) var tickCount = 0

    func waitForNextSecond() async throws {
        tickCount += 1
        await Task.yield()
    }
}

private actor M5SessionPreparer: PracticeSessionPreparing {
    func prepareNewSource(at _: URL) async throws -> PreparedPractice {
        throw M5TestError.unexpectedPreparation
    }

    func prepareExistingProject(id _: UUID) async throws -> PreparedPractice {
        throw M5TestError.unexpectedPreparation
    }

    func relocateProject(id _: UUID, to _: URL) async throws -> PreparedPractice {
        throw M5TestError.unexpectedPreparation
    }

    func endSession() {}
}

private enum M5TestError: Error {
    case unexpectedPreparation
}

private extension PracticeAudioCommand {
    var isBeginRecording: Bool {
        if case .beginRecording = self {
            return true
        }
        return false
    }
}
