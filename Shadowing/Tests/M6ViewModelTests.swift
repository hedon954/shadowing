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
        // selectTake syncs the practice selection to the take's interval, so the snapshot
        // notice for a mismatched region is cleared.
        XCTAssertEqual(fixture.viewModel.project.currentRegion, first.region)
        XCTAssertNil(fixture.viewModel.comparisonRegionNotice)
    }

    func testSelectTakeJumpsPlayheadToTakeStartAndSyncsSelection() async throws {
        let fixture = try await makeFixtureWithCommittedTake()
        let take = try XCTUnwrap(fixture.viewModel.activeTake)
        let elsewhere = try PracticeRegion(start: 8, end: 12, sourceDuration: 30)
        fixture.viewModel.selectRegion(elsewhere)
        // Move the playhead outside the take directly, without a seek command.
        fixture.viewModel.playhead = 20
        fixture.viewModel.project.playhead = 20
        XCTAssertTrue(fixture.viewModel.loopEnabled)

        fixture.viewModel.selectTake(take)

        XCTAssertEqual(fixture.viewModel.activeTake?.id, take.id)
        XCTAssertEqual(fixture.viewModel.playhead, take.region.start, accuracy: 0.001)
        XCTAssertEqual(fixture.viewModel.project.currentRegion, take.region)
        // Clicking a take leaves loop as the user set it (on here); it must not toggle it.
        XCTAssertTrue(fixture.viewModel.loopEnabled)
        XCTAssertFalse(fixture.viewModel.isPlaying)
        XCTAssertNil(fixture.viewModel.comparison)
    }

    func testSelectTakeDoesNotEnableLoopAsSideEffect() async throws {
        let fixture = try await makeFixtureWithCommittedTake()
        let take = try XCTUnwrap(fixture.viewModel.activeTake)
        fixture.viewModel.setLoopEnabled(false)
        XCTAssertFalse(fixture.viewModel.loopEnabled)

        fixture.viewModel.selectTake(take)

        XCTAssertEqual(fixture.viewModel.project.currentRegion, take.region)
        XCTAssertEqual(fixture.viewModel.playhead, take.region.start, accuracy: 0.001)
        XCTAssertFalse(fixture.viewModel.loopEnabled)
    }

    func testSelectTakeForcesSeekWhileOriginalPlayingInsideTakeRegion() async throws {
        let fixture = try await makeFixtureWithCommittedTake()
        let take = try XCTUnwrap(fixture.viewModel.activeTake)
        // Play original with the playhead already inside the take region — the old
        // selectRegion "resume inside loop" path would keep this position.
        fixture.viewModel.playhead = take.region.start + 0.4
        fixture.viewModel.project.playhead = take.region.start + 0.4
        fixture.viewModel.isPlaying = true
        fixture.viewModel.playingTakeID = nil
        let commandsBefore = await fixture.audio.commands.count

        fixture.viewModel.selectTake(take)

        XCTAssertEqual(fixture.viewModel.playhead, take.region.start, accuracy: 0.001)
        XCTAssertFalse(fixture.viewModel.isPlaying)
        XCTAssertNil(fixture.viewModel.playingTakeID)
        await M6TestSupport.waitUntilAsync {
            let commands = await fixture.audio.commands
            guard commands.count > commandsBefore else {
                return false
            }
            return commands.suffix(commands.count - commandsBefore).contains {
                if case let .seek(position) = $0 {
                    return abs(position - take.region.start) < 0.001
                }
                return false
            }
        }
    }

    func testSelectTakeForcesSeekWhileCompareInProgress() async throws {
        let fixture = try await makeFixtureWithCommittedTake()
        let take = try XCTUnwrap(fixture.viewModel.activeTake)
        fixture.viewModel.setCompareMode(.original)
        fixture.viewModel.compare()
        XCTAssertNotNil(fixture.viewModel.comparison)
        // Simulate compare having moved the playhead into the take region.
        fixture.viewModel.playhead = take.region.start + 0.5
        fixture.viewModel.isPlaying = true
        let commandsBefore = await fixture.audio.commands.count

        fixture.viewModel.selectTake(take)

        XCTAssertNil(fixture.viewModel.comparison)
        XCTAssertEqual(fixture.viewModel.playhead, take.region.start, accuracy: 0.001)
        XCTAssertFalse(fixture.viewModel.isPlaying)
        await M6TestSupport.waitUntilAsync {
            let commands = await fixture.audio.commands
            guard commands.count > commandsBefore else {
                return false
            }
            return commands.suffix(commands.count - commandsBefore).contains {
                if case let .seek(position) = $0 {
                    return abs(position - take.region.start) < 0.001
                }
                return false
            }
        }
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

    /// ADR-0012: with a take selected, Record still adds a new take and leaves the selected one alone.
    func testSelectedTakeRecordAddsNewTakeAndKeepsTheSelectedOne() async throws {
        let fixture = try await makeFixtureWithCommittedTake()
        let existing = try XCTUnwrap(fixture.viewModel.activeTake)
        XCTAssertEqual(fixture.viewModel.recordingTakeNumber, existing.sequence + 1, "shown before recording")
        let existingFile = try fixture.fileStore.audioURL(relativePath: existing.relativeAudioPath)
        let existingBytes = try Data(contentsOf: existingFile)
        let commandCountBefore = await fixture.audio.commands.count

        fixture.viewModel.startRecording()
        let temporaryURL = await M6TestSupport.waitForBeginRecording(
            audio: fixture.audio,
            afterCommandCount: commandCountBefore
        )

        XCTAssertFalse(temporaryURL.lastPathComponent.hasPrefix(existing.id.uuidString))
        XCTAssertEqual(fixture.viewModel.recordingTakeNumber, existing.sequence + 1)
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
            fixture.viewModel.takes.count == 2
        }

        let kept = try XCTUnwrap(fixture.viewModel.takes.first { $0.id == existing.id })
        XCTAssertEqual(kept, existing, "the selected take is not touched")
        XCTAssertEqual(try Data(contentsOf: existingFile), existingBytes)
        let newest = try XCTUnwrap(fixture.viewModel.takes.first)
        XCTAssertNotEqual(newest.id, existing.id)
        XCTAssertEqual(newest.sequence, existing.sequence + 1)
        XCTAssertEqual(newest.duration, 2.0)
        XCTAssertEqual(fixture.viewModel.activeTake?.id, newest.id, "the new take is selected for comparing")
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
