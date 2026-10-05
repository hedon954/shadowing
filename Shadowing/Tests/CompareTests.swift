import Foundation
@testable import Shadowing
import XCTest

/// Compare plays only the chosen sentence: original, mine, or original then mine.
final class ComparePlannerTests: XCTestCase {
    private func take(regionStart: TimeInterval, duration: TimeInterval) throws -> Take {
        let region = try PracticeRegion.takeAlignment(start: regionStart, end: 120, sourceDuration: 130)
        return try Take(
            projectID: UUID(),
            region: region,
            sequence: 1,
            relativeAudioPath: "x.caf",
            duration: duration,
            createdAt: Date(timeIntervalSince1970: 0)
        )
    }

    private let sentence = SentenceChunk(start: 48, end: 65)

    func testOriginalThenMineAppliesTheOffset() throws {
        let take = try take(regionStart: 40, duration: 60)
        let steps = ComparePlanner.steps(
            sentence: sentence, sourceDuration: 130, take: take, offset: 0.3, mode: .originalThenMine
        )
        XCTAssertEqual(steps.count, 2)
        guard case let .original(original) = steps[0], case let .take(id, part) = steps[1] else {
            return XCTFail("\(steps)")
        }
        XCTAssertEqual(original.start, 48)
        XCTAssertEqual(original.end, 65)
        XCTAssertEqual(id, take.id)
        XCTAssertEqual(part.start, 8.3, accuracy: 1e-9)
        XCTAssertEqual(part.end, 25.3, accuracy: 1e-9)
    }

    func testOldTakeWithoutMeasurementUsesZeroOffset() throws {
        let take = try take(regionStart: 40, duration: 60)
        let steps = ComparePlanner.steps(sentence: sentence, sourceDuration: 130, take: take, offset: 0, mode: .mine)
        XCTAssertEqual(steps.count, 1)
        guard case let .take(_, part) = steps[0] else {
            return XCTFail("\(steps)")
        }
        XCTAssertEqual(part.start, 8, accuracy: 1e-9)
        XCTAssertEqual(part.end, 25, accuracy: 1e-9)
    }

    func testTakeShorterThanTheSentenceIsClippedToWhatWasRecorded() throws {
        let take = try take(regionStart: 40, duration: 12)
        let steps = ComparePlanner.steps(sentence: sentence, sourceDuration: 130, take: take, offset: 0.1, mode: .mine)
        guard case let .take(_, part) = steps.first else {
            return XCTFail("\(steps)")
        }
        XCTAssertEqual(part.start, 8.1, accuracy: 1e-9)
        XCTAssertEqual(part.end, 12, accuracy: 1e-9)
    }

    func testTakeThatEndsBeforeTheSentenceOnlyPlaysTheOriginal() throws {
        let take = try take(regionStart: 40, duration: 5)
        let both = ComparePlanner.steps(
            sentence: sentence, sourceDuration: 130, take: take, offset: 0, mode: .originalThenMine
        )
        XCTAssertEqual(both.count, 1)
        XCTAssertTrue(ComparePlanner.steps(sentence: sentence, sourceDuration: 130, take: take, offset: 0, mode: .mine)
            .isEmpty)
        XCTAssertTrue(ComparePlanner.steps(sentence: sentence, sourceDuration: 130, take: nil, offset: 0, mode: .mine)
            .isEmpty)
    }
}

@MainActor
final class CompareViewModelTests: XCTestCase {
    func testCompareRunsOriginalThenMineForTheLoopRangeWithTheMeasuredOffset() async throws {
        let fixture = try await M9TestSupport.makeFixtureWithCommittedTake(testCase: self, measuredOffset: 0.2)
        let model = fixture.viewModel
        let take = try XCTUnwrap(model.takes.first)
        await M9TestSupport.waitUntil { model.alignmentOffset(for: take.id) > 0 }
        XCTAssertEqual(model.currentSentenceWithSource?.source, .loopRange)

        model.compare()
        XCTAssertNotNil(model.comparison)
        await M9TestSupport.waitUntilAsync {
            await fixture.audio.commands.contains { command in
                if case let .playOriginalSegment(region, from, _) = command {
                    return region.start == fixture.region.start && region.end == fixture.region.end
                        && from == fixture.region.start
                }
                return false
            }
        }
        await fixture.audio.emit(.playbackFinished)
        // The take is 1.5 s long, shorter than the 3 s sentence: play 0.2–1.5 of the take file.
        let expected = try PracticeRegion.takeAlignment(start: 0.2, end: 1.5, sourceDuration: take.duration)
        await M9TestSupport.waitUntilAsync {
            await fixture.audio.commands.contains { command in
                if case let .playTakeSegment(id, region) = command {
                    return id == take.id && abs(region.start - expected.start) < 1e-9
                        && abs(region.end - expected.end) < 1e-9
                }
                return false
            }
        }
        XCTAssertEqual(model.playingTakeID, take.id)
        await fixture.audio.emit(.playbackFinished)
        await M9TestSupport.waitUntil { model.comparison == nil }
        XCTAssertNil(model.playingTakeID)
        XCTAssertEqual(model.playhead, fixture.region.start, accuracy: 1e-9)
    }

    func testPressingCompareAgainStopsAndPlayCancelsIt() async throws {
        let fixture = try await M9TestSupport.makeFixtureWithCommittedTake(testCase: self)
        let model = fixture.viewModel
        model.setCompareMode(.original)
        model.compare()
        XCTAssertNotNil(model.comparison)
        model.compare()
        XCTAssertNil(model.comparison)
        await M9TestSupport.waitForCommand(.pause, audio: fixture.audio)

        model.compare()
        model.togglePlayback()
        XCTAssertNil(model.comparison, "any transport action ends the comparison")
    }

    func testCompareWithTakeDoesNotChangeSelectionPlayheadOrLoop() async throws {
        let fixture = try await M9TestSupport.makeFixtureWithCommittedTake(testCase: self)
        let model = fixture.viewModel
        let first = try XCTUnwrap(model.activeTake)
        let secondRegion = try PracticeRegion(start: 10, end: 13, sourceDuration: 30)
        let second = try Take(
            projectID: fixture.project.id,
            region: secondRegion,
            sequence: 2,
            relativeAudioPath: "takes/second.caf",
            duration: 1.5,
            createdAt: Date(timeIntervalSince1970: 300)
        )
        model.takes = [first, second]
        model.activeTake = first
        model.project.selectedTakeID = first.id
        model.seek(to: 6)
        await M9TestSupport.waitForCommand(.seek(6), audio: fixture.audio)
        let loopBefore = model.loopEnabled
        let regionBefore = model.region
        let playheadBefore = model.playhead
        let selectedBefore = model.activeTake?.id

        model.setCompareMode(.original)
        model.compare(with: second)

        XCTAssertEqual(model.comparison?.takeID, second.id)
        XCTAssertEqual(model.activeTake?.id, selectedBefore, "Compare must not change selection")
        XCTAssertEqual(model.region, regionBefore, "Compare must not change selection region")
        XCTAssertEqual(model.loopEnabled, loopBefore, "Compare must not touch loop")
        // Playhead may move for the compare step itself; stop restores the prior playhead.
        model.compare() // stop
        XCTAssertNil(model.comparison)
        XCTAssertEqual(model.playhead, playheadBefore, accuracy: 1e-9)
        XCTAssertEqual(model.activeTake?.id, selectedBefore)
        XCTAssertEqual(model.region, regionBefore)
        XCTAssertEqual(model.loopEnabled, loopBefore)
    }

    func testCompareDoesNotGoThroughSelectTake() async throws {
        let fixture = try await M9TestSupport.makeFixtureWithCommittedTake(testCase: self)
        let model = fixture.viewModel
        let take = try XCTUnwrap(model.activeTake)
        model.clearTakeSelection()
        XCTAssertNil(model.activeTake)
        let regionBefore = model.region
        let loopBefore = model.loopEnabled
        model.seek(to: 5.5)
        await M9TestSupport.waitForCommand(.seek(5.5), audio: fixture.audio)

        model.setCompareMode(.original)
        model.compare()

        XCTAssertNotNil(model.comparison)
        XCTAssertEqual(model.comparison?.takeID, take.id, "uses newest/available take for playback")
        XCTAssertNil(model.activeTake, "C-key Compare must not select a take")
        XCTAssertEqual(model.region, regionBefore)
        XCTAssertEqual(model.loopEnabled, loopBefore)
    }
}
