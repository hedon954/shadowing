import Foundation
@testable import Shadowing
import XCTest

@MainActor
final class M6ViewModelTests: XCTestCase {
    func testSelectTakeIsIdempotentAndClearsViaClearTakeSelection() async throws {
        let fixture = try await makeFixtureWithCommittedTake()
        let take = try XCTUnwrap(fixture.viewModel.activeTake)

        fixture.viewModel.selectTake(take)
        XCTAssertEqual(fixture.viewModel.activeTake?.id, take.id)

        fixture.viewModel.clearTakeSelection()
        XCTAssertNil(fixture.viewModel.activeTake)
        XCTAssertNil(fixture.viewModel.project.selectedTakeID)

        fixture.viewModel.selectTake(take)
        XCTAssertEqual(fixture.viewModel.activeTake?.id, take.id)
    }

    func testSelectTakeSwitchesActiveTakeWithoutOverwritingOthers() async throws {
        let fixture = try await makeFixtureWithCommittedTake()
        let first = try XCTUnwrap(fixture.viewModel.activeTake)
        let secondRegion = try PracticeRegion(start: 10, end: 13, sourceDuration: 30)
        let second = try await commitAdditionalTake(
            fixture: fixture,
            region: secondRegion,
            sequence: 2,
            createdAt: Date(timeIntervalSince1970: 300)
        )

        await fixture.viewModel.focusTake(second)
        fixture.viewModel.selectTake(first)

        XCTAssertEqual(fixture.viewModel.activeTake?.id, first.id)
        XCTAssertEqual(fixture.viewModel.takes.count, 2)
        XCTAssertEqual(
            Set(fixture.viewModel.takes.map(\.id)),
            Set([first.id, second.id])
        )
        XCTAssertNotNil(fixture.viewModel.comparisonRegionNotice)
    }

    func testDeleteCurrentTakeSelectsMostRecentRemaining() async throws {
        let fixture = try await makeFixtureWithCommittedTake()
        let first = try XCTUnwrap(fixture.viewModel.activeTake)
        let second = try await commitAdditionalTake(
            fixture: fixture,
            region: fixture.region,
            sequence: 2,
            createdAt: Date(timeIntervalSince1970: 400)
        )
        await fixture.viewModel.refreshTakes()
        fixture.viewModel.selectTake(second)

        fixture.viewModel.requestDeleteTake(second)
        await M6TestSupport.waitUntil {
            fixture.viewModel.activeTake?.id == first.id
        }

        XCTAssertEqual(fixture.viewModel.takes.map(\.id), [first.id])
        XCTAssertEqual(fixture.viewModel.activeTake?.id, first.id)
        XCTAssertEqual(fixture.viewModel.recordingPresentation, .idle)
        XCTAssertTrue(fixture.viewModel.showsMultiTrackWorkspace)
    }

    func testDeleteLastTakeReturnsToPractice() async throws {
        let fixture = try await makeFixtureWithCommittedTake()
        let take = try XCTUnwrap(fixture.viewModel.activeTake)

        fixture.viewModel.requestDeleteTake(take)
        await M6TestSupport.waitUntil {
            fixture.viewModel.takes.isEmpty
        }

        XCTAssertTrue(fixture.viewModel.takes.isEmpty)
        XCTAssertNil(fixture.viewModel.activeTake)
        XCTAssertNil(fixture.viewModel.project.selectedTakeID)
        XCTAssertFalse(fixture.viewModel.isComparing)
        XCTAssertFalse(fixture.viewModel.showsMultiTrackWorkspace)
    }

    func testSelectedTakeRecordOverwritesSameTake() async throws {
        let fixture = try await makeFixtureWithCommittedTake()
        let existing = try XCTUnwrap(fixture.viewModel.activeTake)
        let commandCountBefore = await fixture.audio.commands.count

        fixture.viewModel.startRecording()
        let temporaryURL = await M6TestSupport.waitForBeginRecording(
            audio: fixture.audio,
            afterCommandCount: commandCountBefore
        )

        XCTAssertTrue(temporaryURL.lastPathComponent.hasPrefix(existing.id.uuidString))
        try Data([2, 2, 2, 2]).write(to: temporaryURL)
        await fixture.audio.emit(.recordingStarted)
        await fixture.audio.emit(
            .recordingFinished(
                url: temporaryURL,
                duration: 2.0,
                reason: .manual
            )
        )
        await M6TestSupport.waitUntil {
            fixture.viewModel.takes.count == 1
                && fixture.viewModel.activeTake?.duration == 2.0
        }

        XCTAssertEqual(fixture.viewModel.takes.map(\.id), [existing.id])
        XCTAssertEqual(fixture.viewModel.activeTake?.id, existing.id)
        XCTAssertEqual(fixture.viewModel.activeTake?.sequence, existing.sequence)
    }

    func testUnselectedRecordAppendsNewTake() async throws {
        let fixture = try await makeFixtureWithCommittedTake()
        let existing = try XCTUnwrap(fixture.viewModel.activeTake)
        fixture.viewModel.clearTakeSelection()
        let commandCountBefore = await fixture.audio.commands.count

        fixture.viewModel.startRecording()
        let temporaryURL = await M6TestSupport.waitForBeginRecording(
            audio: fixture.audio,
            afterCommandCount: commandCountBefore
        )
        XCTAssertFalse(temporaryURL.lastPathComponent.hasPrefix(existing.id.uuidString))
        try Data([3, 3, 3, 3]).write(to: temporaryURL)
        await fixture.audio.emit(.recordingStarted)
        await fixture.audio.emit(
            .recordingFinished(
                url: temporaryURL,
                duration: 1.5,
                reason: .manual
            )
        )
        await M6TestSupport.waitUntil {
            fixture.viewModel.takes.count == 2
        }

        XCTAssertEqual(Set(fixture.viewModel.takes.map(\.id)).count, 2)
        XCTAssertTrue(fixture.viewModel.takes.contains(where: { $0.id == existing.id }))
        let newest = try XCTUnwrap(fixture.viewModel.takes.first)
        XCTAssertNotEqual(newest.id, existing.id)
        XCTAssertEqual(newest.sequence, existing.sequence + 1)
        XCTAssertLessThan(newest.displayOrder, existing.displayOrder)
    }

    func testTakePlayButtonStartsFromTakeBeginning() async throws {
        let fixture = try await makeFixtureWithCommittedTake()
        let take = try XCTUnwrap(fixture.viewModel.activeTake)
        fixture.viewModel.setLoopEnabled(false)
        fixture.viewModel.seekTimeline(take.region.start + 0.5)

        fixture.viewModel.toggleTakePlayback(take)
        await M6TestSupport.waitForCommand(
            .playTake(takeID: take.id, from: 0, loop: nil),
            audio: fixture.audio
        )
        XCTAssertEqual(fixture.viewModel.playhead, take.region.start)
        XCTAssertEqual(fixture.viewModel.playingTakeID, take.id)
    }

    func testOriginalTransportStillPlaysOriginalWithTakesPresent() async throws {
        let fixture = try await makeFixtureWithCommittedTake()
        fixture.viewModel.seekTimeline(25)
        fixture.viewModel.togglePlayback()
        await M6TestSupport.waitForCommand(
            .playOriginal(region: nil, from: 25, rate: 1),
            audio: fixture.audio
        )
        XCTAssertNil(fixture.viewModel.playingTakeID)
    }

    func testChangingPracticeRegionDoesNotMutateTakeSnapshot() async throws {
        let fixture = try await makeFixtureWithCommittedTake()
        let take = try XCTUnwrap(fixture.viewModel.activeTake)
        let newRegion = try PracticeRegion(start: 8, end: 12, sourceDuration: 30)

        fixture.viewModel.selectRegion(newRegion)

        let stored = try await fixture.takes.take(id: take.id)
        XCTAssertEqual(stored?.region, take.region)
        XCTAssertEqual(fixture.viewModel.activeTake?.region, take.region)
    }

    private func makeFixtureWithCommittedTake() async throws -> M6Fixture {
        let pair = try await M6TestSupport.makeFixtureWithCommittedTake()
        let root = pair.temporaryRoot
        addTeardownBlock {
            try FileManager.default.removeItem(at: root)
        }
        return pair.fixture
    }

    private func commitAdditionalTake(
        fixture: M6Fixture,
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
}
