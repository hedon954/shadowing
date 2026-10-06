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
        await fixture.audio.emit(.segmentFinished)
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
        let commandsBeforeFinish = await fixture.audio.commands.count
        await fixture.audio.emit(.segmentFinished)
        await M9TestSupport.waitUntil { model.comparison == nil }
        XCTAssertNil(model.playingTakeID)
        XCTAssertEqual(model.playhead, fixture.region.start, accuracy: 1e-9)
        await M9TestSupport.waitUntilAsync {
            let commands = await fixture.audio.commands
            guard commands.count > commandsBeforeFinish else {
                return false
            }
            return commands.suffix(commands.count - commandsBeforeFinish).contains {
                if case let .seek(position) = $0 {
                    return abs(position - fixture.region.start) < 1e-9
                }
                return false
            }
        }
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
        XCTAssertEqual(model.playhead, playheadBefore, accuracy: 1e-9, "Compare freezes the playhead")
        let commandsBeforeStop = await fixture.audio.commands.count
        model.compare() // stop
        XCTAssertNil(model.comparison)
        XCTAssertEqual(model.playhead, playheadBefore, accuracy: 1e-9)
        XCTAssertEqual(model.activeTake?.id, selectedBefore)
        XCTAssertEqual(model.region, regionBefore)
        XCTAssertEqual(model.loopEnabled, loopBefore)
        await M9TestSupport.waitUntilAsync {
            let commands = await fixture.audio.commands
            guard commands.count > commandsBeforeStop else {
                return false
            }
            return commands.suffix(commands.count - commandsBeforeStop).contains {
                if case let .seek(position) = $0 {
                    return abs(position - playheadBefore) < 1e-9
                }
                return false
            }
        }
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

    func testFinishAndStopComparisonSeekEngineToRestoredPlayhead() async throws {
        let fixture = try await M9TestSupport.makeFixtureWithCommittedTake(testCase: self)
        let model = fixture.viewModel
        model.seek(to: 7.25)
        await M9TestSupport.waitForCommand(.seek(7.25), audio: fixture.audio)
        model.setCompareMode(.original)

        model.compare()
        XCTAssertNotNil(model.comparison)
        let commandsBeforeFinish = await fixture.audio.commands.count
        await fixture.audio.emit(.segmentFinished)
        await M9TestSupport.waitUntil { model.comparison == nil }
        XCTAssertEqual(model.playhead, 7.25, accuracy: 1e-9)
        await M9TestSupport.waitUntilAsync {
            let commands = await fixture.audio.commands
            guard commands.count > commandsBeforeFinish else {
                return false
            }
            return commands.suffix(commands.count - commandsBeforeFinish).contains {
                if case let .seek(position) = $0 {
                    return abs(position - 7.25) < 1e-9
                }
                return false
            }
        }

        model.seek(to: 4.5)
        await M9TestSupport.waitForCommand(.seek(4.5), audio: fixture.audio)
        model.compare()
        XCTAssertNotNil(model.comparison)
        let commandsBeforeStop = await fixture.audio.commands.count
        model.compare() // stop → stopComparison → cancelComparison
        XCTAssertNil(model.comparison)
        XCTAssertEqual(model.playhead, 4.5, accuracy: 1e-9)
        await M9TestSupport.waitUntilAsync {
            let commands = await fixture.audio.commands
            guard commands.count > commandsBeforeStop else {
                return false
            }
            return commands.suffix(commands.count - commandsBeforeStop).contains {
                if case let .seek(position) = $0 {
                    return abs(position - 4.5) < 1e-9
                }
                return false
            }
        }
    }

    func testStopComparisonThenImmediateSpacePlaysFromRestoredPlayhead() async throws {
        let fixture = try await M9TestSupport.makeFixtureWithCommittedTake(testCase: self)
        let model = fixture.viewModel
        model.seek(to: 5)
        await M9TestSupport.waitForCommand(.seek(5), audio: fixture.audio)
        model.setCompareMode(.original)
        model.compare()
        await M9TestSupport.waitUntil { model.isPlaying }
        XCTAssertNotNil(model.comparison)

        let commandsBeforeStop = await fixture.audio.commands.count
        model.compare() // stop — must clear isPlaying before async pause finishes
        XCTAssertNil(model.comparison)
        XCTAssertFalse(model.isPlaying, "isPlaying must clear synchronously so Space plays, not pauses")
        XCTAssertEqual(model.playhead, 5, accuracy: 1e-9)

        model.togglePlayback() // immediate Space (C then Space rhythm)
        await M9TestSupport.waitUntilAsync {
            let commands = await fixture.audio.commands
            guard commands.count > commandsBeforeStop else {
                return false
            }
            return commands.suffix(commands.count - commandsBeforeStop).contains {
                if case let .playOriginal(_, from, _) = $0 {
                    return abs(from - 5) < 1e-9
                }
                return false
            }
        }
        let commands = await fixture.audio.commands
        let suffix = Array(commands.suffix(max(0, commands.count - commandsBeforeStop)))
        let pauseOnly = suffix.allSatisfy {
            if case .pause = $0 {
                return true
            }
            if case .seek = $0 {
                return true
            }
            return false
        }
        XCTAssertFalse(pauseOnly, "Space after stop must start play from restored playhead, not only pause")
        XCTAssertTrue(
            suffix.contains {
                if case let .playOriginal(_, from, _) = $0 {
                    return abs(from - 5) < 1e-9
                }
                return false
            }
        )
    }

    func testLatePlayheadChangedAfterCompareDoesNotOverwriteRestoredPlayhead() async throws {
        let fixture = try await M9TestSupport.makeFixtureWithCommittedTake(testCase: self)
        let model = fixture.viewModel
        let take = try XCTUnwrap(model.takes.first)
        model.seek(to: 7.25)
        await M9TestSupport.waitForCommand(.seek(7.25), audio: fixture.audio)
        model.setCompareMode(.original)
        model.compare()
        await M9TestSupport.waitUntil { model.isPlaying }

        // Finish synchronously on MainActor so restore gating is still active before any await.
        model.receive(.segmentFinished)
        XCTAssertNil(model.comparison)
        XCTAssertEqual(model.playhead, 7.25, accuracy: 1e-9)
        model.receive(.playheadChanged(take.duration))
        model.receive(.playheadChanged(fixture.region.end))
        XCTAssertEqual(
            model.playhead,
            7.25,
            accuracy: 1e-9,
            "late playheadChanged must not overwrite restored playhead until seek completes"
        )

        // Stop path: same late-tick protection (no await between stop and receive).
        model.seek(to: 4.5)
        await M9TestSupport.waitForCommand(.seek(4.5), audio: fixture.audio)
        model.compare()
        await M9TestSupport.waitUntil { model.isPlaying }
        model.compare() // stop
        XCTAssertNil(model.comparison)
        XCTAssertEqual(model.playhead, 4.5, accuracy: 1e-9)
        model.receive(.playheadChanged(fixture.region.end))
        model.receive(.playheadChanged(take.duration))
        XCTAssertEqual(
            model.playhead,
            4.5,
            accuracy: 1e-9,
            "late playheadChanged after stop must not stick"
        )
    }
}
