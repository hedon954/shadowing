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

    func testLibraryListMergesProjectsAndSortsByActivity() async throws {
        let storage = InMemoryPersistence()
        let projects = InMemoryProjectRepository(storage: storage)
        let takes = InMemoryTakeRepository(storage: storage)
        let olderOpen = M9TestSupport.makeProject(name: "OlderOpen.mp3", openedAt: 100)
        let newerWithTake = M9TestSupport.makeProject(name: "NewerTake.mp3", openedAt: 200)
        let newestOpen = M9TestSupport.makeProject(name: "NewestOpen.mp3", openedAt: 400)
        try await projects.save(olderOpen)
        try await projects.save(newerWithTake)
        try await projects.save(newestOpen)

        let region = try PracticeRegion(start: 1, end: 3, sourceDuration: 30)
        try await takes.save(
            Take(
                projectID: newerWithTake.id,
                region: region,
                sequence: 1,
                relativeAudioPath: "b.caf",
                duration: 2,
                createdAt: Date(timeIntervalSince1970: 500)
            )
        )

        let viewModel = FilesViewModel(
            chooser: M9FileChooser(),
            sessionPreparer: M9SessionPreparer(),
            projects: projects,
            takes: takes
        ) { _ in }
        await viewModel.loadLibrary()

        // Activity: newerWithTake (take at 500) > newestOpen (400) > olderOpen (100)
        XCTAssertEqual(viewModel.libraryItems.map(\.project.sourceDisplayName), [
            "NewerTake.mp3",
            "NewestOpen.mp3",
            "OlderOpen.mp3"
        ])
        XCTAssertEqual(viewModel.libraryItems.map(\.takeCount), [1, 0, 0])
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
