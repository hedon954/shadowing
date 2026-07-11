import Foundation
@testable import Shadowing
import XCTest

@MainActor
final class M7ViewModelTests: XCTestCase {
    func testHydrateRestoresRegionRateSelectedTakeAndPlayhead() async throws {
        let fixture = try await M7TestSupport.makeHydrateFixture(testCase: self)
        fixture.viewModel.playheadPersistDelay = .milliseconds(1)
        fixture.viewModel.start()
        await fixture.viewModel.hydrateRestoredSession()

        XCTAssertEqual(fixture.viewModel.recordingPresentation, .idle)
        XCTAssertTrue(fixture.viewModel.showsMultiTrackWorkspace)

        XCTAssertEqual(fixture.viewModel.rate, 0.75)
        XCTAssertEqual(fixture.viewModel.activeTake?.id, fixture.take.id)
        XCTAssertEqual(fixture.viewModel.takes, [fixture.take])
        XCTAssertEqual(fixture.viewModel.project.currentRegion, fixture.region)
        XCTAssertEqual(fixture.viewModel.project.playhead, fixture.region.start)
        XCTAssertEqual(fixture.viewModel.project.playbackRate, 0.75)

        fixture.viewModel.setRate(1.25)
        await M7TestSupport.waitUntil {
            let saved = try? await fixture.projects.project(id: fixture.projectID)
            return saved?.playbackRate == 1.25
        }
        XCTAssertEqual(fixture.viewModel.project.playbackRate, 1.25)
    }

    func testPlayheadPersistIsDebouncedWhileCriticalStateSavesImmediately() async throws {
        let storage = InMemoryPersistence()
        let projects = InMemoryProjectRepository(storage: storage)
        let prepared = M7TestSupport.makePreparedPractice(playhead: 0)
        try await projects.save(prepared.project)
        let audio = PracticeAudioClientSpy()
        let viewModel = PracticeViewModel(
            prepared: prepared,
            audioClient: audio,
            projects: projects,
            sessionPreparer: M7SessionPreparer()
        )
        viewModel.playheadPersistDelay = .milliseconds(80)
        viewModel.start()
        await M7TestSupport.waitForCommand(.setVolume(0.8), audio: audio)

        viewModel.togglePlayback()
        await M7TestSupport.waitUntil { viewModel.isPlaying }
        await audio.emit(.playheadChanged(2))
        await audio.emit(.playheadChanged(4))
        await audio.emit(.playheadChanged(6))
        await M7TestSupport.waitUntil { viewModel.playhead == 6 }

        let midSave = try await projects.project(id: prepared.project.id)
        XCTAssertEqual(midSave?.playhead, 0)

        try await Task.sleep(for: .milliseconds(120))
        let debounced = try await projects.project(id: prepared.project.id)
        XCTAssertEqual(debounced?.playhead, 6)

        let region = try PracticeRegion(start: 1, end: 4, sourceDuration: 60)
        viewModel.selectRegion(region)
        await M7TestSupport.waitUntil {
            let saved = try? await projects.project(id: prepared.project.id)
            return saved?.currentRegion == region
        }
    }

    func testLeaveConfirmationStopsRecordingBeforeClosing() async throws {
        let fixture = try await M7TestSupport.makeRecordingFixture(testCase: self)
        fixture.viewModel.startRecording()
        let temporaryURL = await M7TestSupport.waitForBeginRecording(audio: fixture.audio)
        try Data([1, 2, 3, 4]).write(to: temporaryURL)
        await fixture.audio.emit(.recordingStarted)
        await M7TestSupport.waitUntil {
            fixture.viewModel.recordingPresentation == .recording(elapsed: 0)
        }

        var didLeave = false
        fixture.viewModel.requestLeave {
            didLeave = true
        }
        XCTAssertNotNil(fixture.viewModel.leaveConfirmation)
        XCTAssertFalse(didLeave)

        fixture.viewModel.confirmStopAndLeave()
        await M7TestSupport.waitForCommand(.stopRecording, audio: fixture.audio)
        await fixture.audio.emit(
            .recordingFinished(url: temporaryURL, duration: 1.2, reason: .manual)
        )
        await M7TestSupport.waitUntil { didLeave }

        let takes = try await fixture.takes.takes(projectID: fixture.project.id)
        XCTAssertEqual(takes.count, 1)
    }
}
