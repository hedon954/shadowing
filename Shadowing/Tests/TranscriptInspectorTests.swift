import AppKit
@testable import Shadowing
import XCTest

/// The full transcript inspector: lyrics-style emphasis, the source picker and speaker lines.
final class TranscriptInspectorTests: XCTestCase {
    // MARK: - Emphasis

    func testOnlyTheCurrentSentenceUsesThePrimaryLabelColor() {
        XCTAssertEqual(TranscriptLineEmphasis(cueIndex: 4, current: 4), .current)
        XCTAssertEqual(TranscriptLineEmphasis(cueIndex: 3, current: 4), .other, "played lines are secondary")
        XCTAssertEqual(TranscriptLineEmphasis(cueIndex: 5, current: 4), .other, "upcoming lines are secondary")
        XCTAssertEqual(TranscriptLineEmphasis(cueIndex: 0, current: nil), .other)
        XCTAssertEqual(TranscriptLineEmphasis.current.color, .labelColor)
        XCTAssertEqual(TranscriptLineEmphasis.other.color, .secondaryLabelColor)
        XCTAssertEqual(TranscriptLineEmphasis.fontSize, 14, "one size for every line, current included")
        XCTAssertEqual(TranscriptLineEmphasis.bandCornerRadius, 6)
        XCTAssertEqual(TranscriptLineEmphasis.bandAnimationDuration, 0.15, accuracy: 0.001)
        XCTAssertEqual(TranscriptLineEmphasis.manualScrollPause, 3, accuracy: 0.001)
    }

    func testCurrentSentenceBandOpacityFollowsAppearanceAndContrast() {
        XCTAssertEqual(TranscriptLineEmphasis.bandOpacity(dark: false, increaseContrast: false), 0.14, accuracy: 0.001)
        XCTAssertEqual(TranscriptLineEmphasis.bandOpacity(dark: true, increaseContrast: false), 0.24, accuracy: 0.001)
        XCTAssertEqual(TranscriptLineEmphasis.bandOpacity(dark: false, increaseContrast: true), 0.32, accuracy: 0.001)
        XCTAssertEqual(TranscriptLineEmphasis.bandOpacity(dark: true, increaseContrast: true), 0.32, accuracy: 0.001)
    }

    // MARK: - Source picker

    func testSourceNamesAreCleanedLikeProjectTitles() {
        let file = SubtitleSourceOption(kind: .subtitleFile, name: "04-second-hand-ecommerce-idle-asset.srt")
        XCTAssertEqual(file.displayName, "Second hand ecommerce idle asset")
        XCTAssertEqual(SubtitleSourceOption(kind: .alignedText, name: "harbor_notes.txt").displayName, "Harbor notes")
        XCTAssertEqual(SubtitleSourceOption(kind: .fromAudio, name: "From audio").displayName, "From audio")
    }

    func testSourceNameIsHiddenWithASingleSubtitleSource() {
        let file = SubtitleSourceOption(kind: .subtitleFile, name: "talk.srt")
        let text = SubtitleSourceOption(kind: .alignedText, name: "talk.txt")
        let notGenerated = SubtitleSourceOption(kind: .fromAudio, name: "From audio", isReady: false)
        XCTAssertFalse(SubtitleSourcePicker.showsSourceName([]))
        XCTAssertFalse(SubtitleSourcePicker.showsSourceName([file]))
        XCTAssertFalse(
            SubtitleSourcePicker.showsSourceName([file, notGenerated]),
            "an ungenerated source is not a second file"
        )
        XCTAssertTrue(SubtitleSourcePicker.showsSourceName([file, text]))
        XCTAssertNil(SubtitleSourcePicker.shownName(sources: [file, notGenerated], active: .subtitleFile))
        XCTAssertEqual(SubtitleSourcePicker.shownName(sources: [file, text], active: .alignedText), "Talk")
    }

    // MARK: - Speaker lines

    func testSpeakerChangeMidSentenceStartsANewLine() {
        let cues = [
            SubtitleCue(start: 0, end: 3, text: "A: So it's used goods? B: Not exactly."),
            SubtitleCue(start: 3, end: 6, text: "It is about liquidity. A: I see.")
        ]
        let runs = SpeakerLines.runs(for: cues, firstIndex: 10)
        XCTAssertEqual(runs, [
            TranscriptRun(cueIndex: 10, text: "A: So it's used goods?", startsLine: false),
            TranscriptRun(cueIndex: 10, text: "B: Not exactly.", startsLine: true),
            TranscriptRun(cueIndex: 11, text: "It is about liquidity.", startsLine: false),
            TranscriptRun(cueIndex: 11, text: "A: I see.", startsLine: true)
        ])
    }

    func testSpeakerAtTheStartOfALaterCueStartsANewLine() {
        let cues = [
            SubtitleCue(start: 0, end: 2, text: "Right."),
            SubtitleCue(start: 2, end: 4, text: "B：好的。")
        ]
        XCTAssertEqual(SpeakerLines.runs(for: cues, firstIndex: 0).map(\.startsLine), [false, true])
    }

    func testTextWithoutSpeakerLabelsIsUnchanged() {
        let cues = [
            SubtitleCue(start: 0, end: 2, text: "Meet at 3:30 today."),
            SubtitleCue(start: 2, end: 4, text: "The ratio is 2:1, note: not a speaker.")
        ]
        let runs = SpeakerLines.runs(for: cues, firstIndex: 0)
        XCTAssertEqual(runs.map(\.text), cues.map(\.text), "times, ratios and lowercase words are not speakers")
        XCTAssertFalse(runs.contains(where: \.startsLine))
    }

    func testSplittingKeepsEveryWordOfTheStoredCue() {
        let cue = SubtitleCue(start: 0, end: 5, text: "  A: Hi there.  B: Hello.  ")
        let runs = SpeakerLines.runs(for: [cue], firstIndex: 7)
        XCTAssertEqual(runs.map(\.text).joined(separator: " "), "A: Hi there. B: Hello.")
        XCTAssertTrue(runs.allSatisfy { $0.cueIndex == 7 }, "every piece seeks to and highlights the same cue")
        XCTAssertEqual(cue.text, "  A: Hi there.  B: Hello.  ", "stored text is untouched")
    }
}
