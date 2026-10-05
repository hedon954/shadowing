import AppKit
import Foundation
@testable import Shadowing
import XCTest

/// Microphone access is re-read whenever the app becomes active, so allowing it in System Settings
/// works without a restart; opening and playing never ask for access.
@MainActor
final class MicrophonePermissionRecheckTests: XCTestCase {
    func testAllowingAccessInSettingsAndReturningLetsRecordWork() async throws {
        let fixture = try await makeFixture(permission: .denied)
        fixture.viewModel.startRecording()
        await waitUntil { fixture.viewModel.microphonePermissionPrompt == .denied }
        let commandsBeforeGrant = await fixture.audio.commands
        XCTAssertFalse(commandsBeforeGrant.contains(where: Self.isBeginRecording))

        await fixture.permissions.set(.authorized)
        await activateApp(fixture) { fixture.viewModel.microphonePermission == .authorized }

        XCTAssertNil(fixture.viewModel.microphonePermissionPrompt)
        fixture.viewModel.startRecording()
        await waitForCommand(fixture, matching: Self.isBeginRecording)
        let requestCount = await fixture.permissions.requestCount
        XCTAssertEqual(requestCount, 0)
    }

    func testStillDeniedAfterReturningKeepsTheSettingsAlertOnRecord() async throws {
        let fixture = try await makeFixture(permission: .denied)

        await activateApp(fixture) { fixture.viewModel.microphonePermission == .denied }
        XCTAssertNil(fixture.viewModel.microphonePermissionPrompt)

        fixture.viewModel.startRecording()
        await waitUntil { fixture.viewModel.microphonePermissionPrompt == .denied }
        fixture.viewModel.openMicrophoneSettings()
        await waitUntil { await fixture.permissions.openSettingsCount == 1 }
        let commands = await fixture.audio.commands
        XCTAssertFalse(commands.contains(where: Self.isBeginRecording))
    }

    func testOpeningAndPlayingNeverAskForMicrophoneAccess() async throws {
        let fixture = try await makeFixture(permission: .notDetermined)

        fixture.viewModel.send(.togglePlayback)
        await waitForCommand(fixture, matching: Self.isPlayOriginal)
        await activateApp(fixture) { fixture.viewModel.microphonePermission == .notDetermined }

        let requestCount = await fixture.permissions.requestCount
        XCTAssertEqual(requestCount, 0)
        XCTAssertNil(fixture.viewModel.microphonePermissionPrompt)
    }

    // MARK: - Helpers

    private static func isBeginRecording(_ command: PracticeAudioCommand) -> Bool {
        if case .beginRecording = command {
            return true
        }
        return false
    }

    private static func isPlayOriginal(_ command: PracticeAudioCommand) -> Bool {
        if case .playOriginal = command {
            return true
        }
        return false
    }

    private func makeFixture(permission: MicrophonePermissionState) async throws -> RecheckFixture {
        let project = AudioProject(
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
        let region = try PracticeRegion(start: 4, end: 7, sourceDuration: 30)
        let storage = InMemoryPersistence()
        let projects = InMemoryProjectRepository(storage: storage)
        let takes = InMemoryTakeRepository(storage: storage)
        try await projects.save(project)
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("Shadowing-Recheck-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock {
            try FileManager.default.removeItem(at: root)
        }
        let fileStore = LocalRecordingFileStore(rootDirectory: root)
        let audio = PracticeAudioClientSpy()
        let permissions = SwitchableMicrophonePermission(status: permission)
        let center = NotificationCenter()
        let viewModel = PracticeViewModel(
            prepared: PreparedPractice(
                project: project,
                waveform: WaveformPresentation(peaks: [0.2, 0.8, 0.4], warning: nil)
            ),
            audioClient: audio,
            projects: projects,
            sessionPreparer: M7SessionPreparer(),
            recordingDependencies: RecordingDependencies(
                permissions: permissions,
                countdownClock: M7ImmediateCountdownClock(),
                fileStore: fileStore,
                takes: takes,
                committer: RecordingTakeCommitter(
                    fileStore: fileStore,
                    takeRepository: takes,
                    validator: AlwaysPlayableRecordingValidator()
                ),
                trash: .temporaryFolder(),
                countdownSeconds: 0,
                appActivationCenter: center
            )
        )
        viewModel.start()
        viewModel.selectRegion(region)
        let fixture = RecheckFixture(viewModel: viewModel, audio: audio, permissions: permissions, center: center)
        await waitForCommand(fixture) { $0 == .seek(region.start) }
        return fixture
    }

    /// Posts "did become active" until the view model has handled it (the observer starts
    /// asynchronously, so a single early post could be missed).
    private func activateApp(
        _ fixture: RecheckFixture,
        until condition: @MainActor () -> Bool
    ) async {
        for _ in 0 ..< 200 {
            fixture.center.post(name: NSApplication.didBecomeActiveNotification, object: nil)
            for _ in 0 ..< 5 {
                await Task.yield()
            }
            if condition() {
                return
            }
        }
        XCTFail("The view model did not re-read microphone access")
    }

    private func waitForCommand(
        _ fixture: RecheckFixture,
        matching predicate: (PracticeAudioCommand) -> Bool
    ) async {
        for _ in 0 ..< 200 {
            if await fixture.audio.commands.contains(where: predicate) {
                return
            }
            await Task.yield()
        }
        XCTFail("Expected audio command was not sent")
    }

    private func waitUntil(_ condition: @MainActor () async -> Bool) async {
        for _ in 0 ..< 200 {
            if await condition() {
                return
            }
            await Task.yield()
        }
        XCTFail("Condition was not satisfied")
    }
}

private struct RecheckFixture {
    let viewModel: PracticeViewModel
    let audio: PracticeAudioClientSpy
    let permissions: SwitchableMicrophonePermission
    let center: NotificationCenter
}

/// Access the user can change while the app runs (as in System Settings).
private actor SwitchableMicrophonePermission: MicrophonePermissionService {
    private var status: MicrophonePermissionState
    private(set) var requestCount = 0
    private(set) var openSettingsCount = 0

    init(status: MicrophonePermissionState) {
        self.status = status
    }

    func set(_ newStatus: MicrophonePermissionState) {
        status = newStatus
    }

    func authorizationStatus() -> MicrophonePermissionState {
        status
    }

    func requestAuthorization() -> MicrophonePermissionState {
        requestCount += 1
        return status
    }

    func openSystemSettings() {
        openSettingsCount += 1
    }
}
