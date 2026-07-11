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

    func testABPlaybackUsesSchedulerThenPlaysTakeAndStops() async throws {
        let fixture = try await M9TestSupport.makeFixtureWithCommittedTake(
            testCase: self,
            scheduler: ImmediateComparisonPlaybackScheduler()
        )
        let take = try XCTUnwrap(fixture.viewModel.activeTake)
        fixture.viewModel.setComparisonMode(.ab)

        fixture.viewModel.toggleComparisonPlayback()
        await M9TestSupport.waitForCommand(
            .playOriginalSegment(region: take.region, from: take.region.start, rate: 1),
            audio: fixture.audio
        )
        XCTAssertEqual(fixture.viewModel.abPlaybackPhase, .playingOriginal)

        await fixture.audio.emit(.playbackFinished)
        await M9TestSupport.waitForCommand(
            .playTake(takeID: take.id, from: 0),
            audio: fixture.audio
        )
        XCTAssertEqual(fixture.viewModel.abPlaybackPhase, .playingTake)

        await fixture.audio.emit(.playbackFinished)
        await M9TestSupport.waitUntil {
            fixture.viewModel.abPlaybackPhase == .idle && fixture.viewModel.isPlaying == false
        }
    }

    func testTogetherPlaybackIssuesPlayTogetherCommand() async throws {
        let fixture = try await M9TestSupport.makeFixtureWithCommittedTake(testCase: self)
        let take = try XCTUnwrap(fixture.viewModel.activeTake)
        fixture.viewModel.setComparisonMode(.together)

        fixture.viewModel.toggleComparisonPlayback()
        await M9TestSupport.waitForCommand(
            .playTogether(region: take.region, takeID: take.id, rate: 1),
            audio: fixture.audio
        )
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

    func testSettingsStoreRoundTripForAppSettings() async throws {
        let storage = InMemoryPersistence()
        let settings = InMemorySettingsStore(storage: storage)
        let value = AppSettings(
            countdownSeconds: 5,
            playOriginalWhileRecording: false,
            defaultPlaybackRate: 1.25,
            preferredInputDeviceUID: "mic-1"
        )
        try await settings.set(value, for: AppSettings.storeKey)
        let loaded = try await settings.value(for: AppSettings.storeKey, as: AppSettings.self)
        XCTAssertEqual(loaded, value)
    }

    func testRecordingsListSortsByMostRecentTake() async throws {
        let storage = InMemoryPersistence()
        let projects = InMemoryProjectRepository(storage: storage)
        let takes = InMemoryTakeRepository(storage: storage)
        let olderProject = M9TestSupport.makeProject(name: "Older.mp3", openedAt: 100)
        let newerProject = M9TestSupport.makeProject(name: "Newer.mp3", openedAt: 200)
        try await projects.save(olderProject)
        try await projects.save(newerProject)

        let region = try PracticeRegion(start: 1, end: 3, sourceDuration: 30)
        try await takes.save(
            Take(
                projectID: olderProject.id,
                region: region,
                sequence: 1,
                relativeAudioPath: "a.caf",
                duration: 2,
                createdAt: Date(timeIntervalSince1970: 500)
            )
        )
        try await takes.save(
            Take(
                projectID: newerProject.id,
                region: region,
                sequence: 1,
                relativeAudioPath: "b.caf",
                duration: 2,
                createdAt: Date(timeIntervalSince1970: 300)
            )
        )

        let viewModel = RecordingsViewModel(
            projects: projects,
            takes: takes,
            sessionPreparer: M9SessionPreparer(),
            fileChooser: M9FileChooser()
        ) { _ in }
        await viewModel.load()

        XCTAssertEqual(viewModel.items.map(\.project.sourceDisplayName), [
            "Older.mp3",
            "Newer.mp3"
        ])
        XCTAssertEqual(viewModel.items.map(\.takeCount), [1, 1])
    }

    func testAppSettingsNormalizesUnsupportedValues() {
        let settings = AppSettings(
            countdownSeconds: 9,
            playOriginalWhileRecording: true,
            defaultPlaybackRate: 2.0
        )
        XCTAssertEqual(settings.normalizedCountdownSeconds, 3)
        XCTAssertEqual(settings.normalizedPlaybackRate, 1)
        XCTAssertEqual(ComparisonMode.allCases.count, 4)
        XCTAssertEqual(ComparisonMode.ab.displayName, "A/B")
    }

    func testComparisonModeIncludesABAndTogether() throws {
        let project = M9TestSupport.makeProject(name: "Speech.mp3", openedAt: 100)
        let region = try PracticeRegion(start: 1, end: 3, sourceDuration: 30)
        let take = try Take(
            projectID: project.id,
            region: region,
            sequence: 1,
            relativeAudioPath: "t.caf",
            duration: 2,
            createdAt: Date(timeIntervalSince1970: 200)
        )
        var machine = PracticeSessionStateMachine()
        try machine.handle(.openProject(project))
        try machine.handle(.selectRegion(region))
        try machine.handle(.prepareRecording)
        try machine.handle(.beginCountdown(seconds: 0))
        try machine.handle(.stopRecording)
        try machine.handle(.recordingCommitted(take))

        XCTAssertNoThrow(try machine.handle(.selectComparisonMode(.ab)))
        guard case let .comparing(abState) = machine.state else {
            return XCTFail("Expected comparing")
        }
        XCTAssertEqual(abState.mode, .ab)

        XCTAssertNoThrow(try machine.handle(.selectComparisonMode(.together)))
        guard case let .comparing(togetherState) = machine.state else {
            return XCTFail("Expected comparing")
        }
        XCTAssertEqual(togetherState.mode, .together)

        let events = try machine.handle(.play(at: 0))
        XCTAssertEqual(
            events,
            [.comparisonPlaybackRequested(mode: .together, takeID: take.id, at: 0)]
        )
    }
}
