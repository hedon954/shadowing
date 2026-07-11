import Foundation
@testable import Shadowing
import XCTest

@MainActor
final class M9SettingsAndRecordingsTests: XCTestCase {
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
        XCTAssertEqual(settings.normalizedCountdownSeconds, 0)
        XCTAssertEqual(settings.normalizedPlaybackRate, 1)
    }

    func testSessionStateMachineStillModelsLegacyComparisonModes() throws {
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
