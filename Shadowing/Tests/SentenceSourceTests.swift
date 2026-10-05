import Foundation
@testable import Shadowing
import XCTest

private struct FixedPauseChunks: PauseChunkProviding {
    let result: [SentenceChunk]

    func chunks(projectID _: UUID, waveform _: WaveformPresentation) async -> [SentenceChunk] {
        result
    }
}

/// The sentence Return replays and C compares: loop range, else subtitles, else pauses.
@MainActor
final class SentenceSourceTests: XCTestCase {
    private func makeModel(playhead: TimeInterval) -> (PracticeViewModel, PracticeAudioClientSpy) {
        let prepared = M7TestSupport.makePreparedPractice(playhead: playhead)
        let audio = PracticeAudioClientSpy()
        let model = PracticeViewModel(
            prepared: prepared,
            audioClient: audio,
            projects: InMemoryProjectRepository(storage: InMemoryPersistence()),
            sessionPreparer: FixedSessionPreparer(prepared: prepared),
            pauseChunks: FixedPauseChunks(result: [
                SentenceChunk(start: 0.5, end: 2), SentenceChunk(start: 3, end: 5.5)
            ])
        )
        return (model, audio)
    }

    func testPausesAreUsedWithoutSubtitlesAndSnapToTheChunkUnderThePlayhead() async {
        let (model, _) = makeModel(playhead: 4)
        model.start()
        await M9TestSupport.waitUntil { !model.sentenceChunks.isEmpty }
        XCTAssertEqual(model.currentSentenceWithSource?.source, .pauses)
        XCTAssertEqual(model.currentSentence, SentenceChunk(start: 3, end: 5.5))
        model.playhead = 2.5
        XCTAssertEqual(model.currentSentence, SentenceChunk(start: 3, end: 5.5), "between chunks: the next one")
    }

    func testSubtitlesWinOverPausesAndTheLoopRangeWinsOverBoth() async throws {
        let (model, _) = makeModel(playhead: 4)
        model.start()
        await M9TestSupport.waitUntil { !model.sentenceChunks.isEmpty }
        SnapshotFixtures.showTimedSubtitles(in: model)
        XCTAssertEqual(model.currentSentenceWithSource?.source, .subtitles)

        try model.selectRegion(PracticeRegion(start: 10, end: 14, sourceDuration: 60))
        XCTAssertEqual(model.currentSentenceWithSource?.source, .loopRange)
        XCTAssertEqual(model.currentSentence, SentenceChunk(start: 10, end: 14))
    }

    func testReturnReplaysTheCurrentSentenceOfTheOriginalOnce() async {
        let (model, audio) = makeModel(playhead: 4)
        model.start()
        await M9TestSupport.waitUntil { !model.sentenceChunks.isEmpty }
        model.replayCurrentSentence()
        await M9TestSupport.waitUntilAsync {
            await audio.commands.contains { command in
                if case let .playOriginalSegment(region, from, _) = command {
                    return region.start == 3 && region.end == 5.5 && from == 3
                }
                return false
            }
        }
        XCTAssertEqual(model.playhead, 3)
    }
}
