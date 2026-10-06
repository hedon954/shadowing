import Foundation
import GRDB
@testable import Shadowing
import XCTest

/// Repro: selection 0:36–0:44, click the original at 1:20 (outside it), turn the loop on,
/// Cmd-Q (no close, no other save), reopen: the loop must still be on. Runs through the real
/// SQLite repository and the reopen (hydrate) path; turning it off is saved the same way.
@MainActor
final class LoopPersistenceTests: XCTestCase {
    private func openPractice(
        _ project: AudioProject,
        projects: GRDBProjectRepository
    ) async -> (PracticeViewModel, PracticeAudioClientSpy) {
        let audio = PracticeAudioClientSpy()
        let model = PracticeViewModel(
            prepared: PreparedPractice(
                project: project,
                waveform: WaveformPresentation(peaks: [0.2, 0.5], warning: nil)
            ),
            audioClient: audio,
            projects: projects,
            sessionPreparer: M7SessionPreparer()
        )
        model.start()
        await M7TestSupport.waitUntil { model.revealToken > 0 && model.pendingLocalSeek == nil }
        return (model, audio)
    }

    private func savedLoop(_ id: UUID, _ projects: GRDBProjectRepository) async -> Bool? {
        let project = try? await projects.project(id: id)
        return project?.loopEnabled
    }

    func testTurningTheLoopOnOrOffIsSavedAtOnceAndReopensThatWay() async throws {
        let database = try DatabaseQueue()
        try AppDatabase.makeMigrator().migrate(database)
        let projects = GRDBProjectRepository(database: database)
        let region = try PracticeRegion(start: 36, end: 44, sourceDuration: 129)
        let saved = AudioProject(
            id: UUID(),
            sourceDisplayName: "Speech.mp3",
            sourceBookmark: Data([7]),
            duration: 129,
            playhead: 40,
            currentRegion: region,
            selectedTakeID: nil,
            keptTakeID: nil,
            lastOpenedAt: Date(timeIntervalSince1970: 100),
            loopEnabled: false
        )
        try await projects.save(saved)

        let (model, audio) = await openPractice(saved, projects: projects)
        model.seekTimeline(80) // 1:20, outside the selection
        await M7TestSupport.waitForCommand(.seek(80), audio: audio)
        model.setLoopEnabled(true)
        await M7TestSupport.waitUntil { await self.savedLoop(saved.id, projects) == true }
        // Cmd-Q here: the practice is never closed, so nothing else saves.

        let loaded = try await projects.project(id: saved.id)
        let reopened = try XCTUnwrap(loaded)
        XCTAssertTrue(reopened.loopEnabled, "loop on is saved at once")
        XCTAssertEqual(reopened.playhead, 80, accuracy: 1e-9)
        let (again, againAudio) = await openPractice(reopened, projects: projects)
        XCTAssertTrue(again.loopEnabled, "reopened with the loop on")
        XCTAssertEqual(again.playhead, 80, accuracy: 1e-9, "the playhead stays outside the selection")
        await M7TestSupport.waitForCommand(.setLoop(region), audio: againAudio)

        again.setLoopEnabled(false)
        await M7TestSupport.waitUntil { await self.savedLoop(saved.id, projects) == false }
        let loadedOff = try await projects.project(id: saved.id)
        let off = try XCTUnwrap(loadedOff)
        let (third, _) = await openPractice(off, projects: projects)
        XCTAssertFalse(third.loopEnabled, "loop off is saved at once too")
        XCTAssertEqual(third.project.currentRegion?.start, 36, "the selection stays")
    }
}
