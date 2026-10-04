@testable import Shadowing
import XCTest

final class TextAlignerTests: XCTestCase {
    private func words(_ text: String, _ start: TimeInterval = 0, _ step: TimeInterval = 0.5) -> [TranscribedWord] {
        SubtitleTestSupport.words(text, start: start, step: step)
    }

    func testExactSpeechTimesEverySentence() {
        let script = "Hello there. How are you today?\n\nI am fine."
        let spoken = words("Hello there. How are you today? I am fine.", 10, 0.5)
        let alignment = TextAligner.align(script: script, words: spoken)
        XCTAssertEqual(alignment.matchRatio, 1)
        XCTAssertTrue(alignment.isAligned)
        XCTAssertEqual(alignment.cues.map(\.text), ["Hello there.", "How are you today?", "I am fine."])
        XCTAssertEqual(alignment.cues[0].start, 10, accuracy: 0.001)
        XCTAssertEqual(alignment.cues[1].start, 11, accuracy: 0.001)
        XCTAssertEqual(alignment.cues[2].start, 13, accuracy: 0.001)
        XCTAssertEqual(alignment.cues[2].end, 14 + 0.4, accuracy: 0.001)
    }

    func testSixtyPercentMatchIsTheThreshold() {
        let script = "alpha bravo charlie delta echo foxtrot golf hotel india juliet"
        // Four of ten words misrecognized: 60 % match, still aligned.
        let sixty = TextAligner.align(
            script: script,
            words: words("alpha zulu charlie yankee echo xray golf whiskey india juliet")
        )
        XCTAssertEqual(sixty.matchRatio, 0.6, accuracy: 0.0001)
        XCTAssertTrue(sixty.isAligned)
        // Five of ten: below the threshold, shown as plain text.
        let fifty = TextAligner.align(
            script: script,
            words: words("alpha zulu charlie yankee echo xray golf whiskey india victor")
        )
        XCTAssertEqual(fifty.matchRatio, 0.5, accuracy: 0.0001)
        XCTAssertFalse(fifty.isAligned)
        XCTAssertEqual(TextAligner.minimumMatchRatio, 0.6)
    }

    func testUnrelatedSpeechDoesNotAlign() {
        let alignment = TextAligner.align(script: "The quick brown fox.", words: words("Nothing like this at all"))
        XCTAssertEqual(alignment.matchRatio, 0)
        XCTAssertFalse(alignment.isAligned)
        XCTAssertTrue(TextAligner.align(script: "Text.", words: []).cues.isEmpty)
    }

    func testMissedSentenceIsPlacedBetweenItsNeighbours() {
        let script = "One two three. Four five six. Seven eight nine."
        var spoken = words("One two three.", 0, 1)
        spoken += words("Seven eight nine.", 10, 1)
        let alignment = TextAligner.align(script: script, words: spoken)
        XCTAssertEqual(alignment.cues.count, 3)
        XCTAssertGreaterThan(alignment.cues[1].start, alignment.cues[0].start)
        XCTAssertLessThan(alignment.cues[1].end, alignment.cues[2].start + 0.001)
        XCTAssertGreaterThanOrEqual(alignment.cues[1].start, 2.8)
    }

    func testSpeechBeforeTheTextIsSkipped() {
        let script = "Today we talk about rivers. Rivers shape the land."
        let intro = words("welcome back everyone thanks for listening to the show this week", 0, 0.5)
        let body = words("Today we talk about rivers. Rivers shape the land.", 20, 0.5)
        let alignment = TextAligner.align(script: script, words: intro + body)
        XCTAssertEqual(alignment.matchRatio, 1)
        XCTAssertEqual(alignment.cues[0].start, 20, accuracy: 0.001)
    }

    func testSentenceSplitting() {
        let script = """
        Mr. Smith arrived at the
        station. He said “Hi!” Then left

        A new paragraph
        """
        XCTAssertEqual(ScriptSentences.split(script), [
            "Mr. Smith arrived at the station.",
            "He said “Hi!”",
            "Then left",
            "A new paragraph"
        ])
    }

    func testLongSentencesAreBrokenAfterACommaOrAtTheLimit() {
        let long = (1 ... 40).map { $0 == 20 ? "word\($0)," : "word\($0)" }.joined(separator: " ")
        let parts = ScriptSentences.split(long)
        XCTAssertEqual(parts.count, 2)
        XCTAssertTrue(parts[0].hasSuffix("word20,"))
    }

    func testTokensIgnoreCaseAndPunctuation() {
        XCTAssertEqual(TextAligner.normalizedTokens("I'm well-known, “OK”?"), ["im", "well", "known", "ok"])
    }
}
