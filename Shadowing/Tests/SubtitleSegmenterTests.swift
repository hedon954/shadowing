@testable import Shadowing
import XCTest

final class SubtitleSegmenterTests: XCTestCase {
    func testEachSentenceBecomesACue() {
        let words = SubtitleTestSupport.words("Good morning everyone. Today we talk about rivers.", start: 2)
        let cues = SubtitleSegmenter.cues(from: words)
        XCTAssertEqual(cues.map(\.text), ["Good morning everyone.", "Today we talk about rivers."])
        XCTAssertEqual(cues[0].start, 2, accuracy: 0.001)
        XCTAssertEqual(cues[0].end, 2 + 2 * 0.5 + 0.4, accuracy: 0.001)
        XCTAssertEqual(cues[1].start, 3.5, accuracy: 0.001)
    }

    func testLongPauseStartsANewCue() {
        var words = SubtitleTestSupport.words("so I waited", start: 0)
        words += SubtitleTestSupport.words("and then it rained", start: 5)
        let cues = SubtitleSegmenter.cues(from: words)
        XCTAssertEqual(cues.map(\.text), ["so I waited", "and then it rained"])
    }

    func testLongSentencesAreSplitAtACommaOrTheWordLimit() {
        let clause = "one two three four five six seven eight, nine ten eleven twelve."
        XCTAssertEqual(
            SubtitleSegmenter.cues(from: SubtitleTestSupport.words(clause, step: 0.3)).map(\.text),
            ["one two three four five six seven eight,", "nine ten eleven twelve."]
        )
        let run = (1 ... 40).map { "w\($0)" }.joined(separator: " ")
        let cues = SubtitleSegmenter.cues(from: SubtitleTestSupport.words(run, step: 0.2))
        XCTAssertTrue(cues.allSatisfy { $0.text.split(separator: " ").count <= SubtitleSegmenter.maximumWords })
        XCTAssertEqual(cues.map { $0.text.split(separator: " ").count }.reduce(0, +), 40)
    }

    func testSlowSpeechIsSplitByDuration() {
        let cues = SubtitleSegmenter.cues(from: SubtitleTestSupport.words("a b c d e f g h i j", step: 1.5))
        XCTAssertGreaterThan(cues.count, 1)
        for cue in cues {
            XCTAssertLessThanOrEqual(cue.end - cue.start, SubtitleSegmenter.maximumDuration)
        }
    }

    func testNoWordsMeansNoCues() {
        XCTAssertTrue(SubtitleSegmenter.cues(from: []).isEmpty)
        XCTAssertTrue(SubtitleSegmenter.cues(from: [TranscribedWord(text: " ", start: 0, end: 1)]).isEmpty)
        XCTAssertEqual(SubtitleSegmenter.text(of: SubtitleTestSupport.words("Hi there.")), "Hi there.")
    }
}
