@testable import Shadowing
import XCTest

final class SubtitleParserTests: XCTestCase {
    func testSRTWithMarkupAndCRLF() throws {
        let text = "\u{FEFF}1\r\n00:00:01,000 --> 00:00:03,500\r\n<i>Hello</i> there\r\nfriend\r\n\r\n"
            + "2\r\n00:00:04,000 --> 00:00:05,000\r\n{\\an8}Second &amp; last\r\n"
        let cues = try SubtitleParser.parse(text, format: .srt)
        XCTAssertEqual(cues, [
            SubtitleCue(start: 1, end: 3.5, text: "Hello there friend"),
            SubtitleCue(start: 4, end: 5, text: "Second & last")
        ])
    }

    func testVTTSkipsHeaderNotesAndSettings() throws {
        let text = """
        WEBVTT

        NOTE written by hand

        00:01.000 --> 00:02.000 align:start position:10%
        <v Anna>Hi

        cue-2
        00:00:02.500 --> 00:00:04.000
        Bye
        """
        let cues = try SubtitleParser.parse(text, format: .vtt)
        XCTAssertEqual(cues, [
            SubtitleCue(start: 1, end: 2, text: "Hi"),
            SubtitleCue(start: 2.5, end: 4, text: "Bye")
        ])
    }

    func testLRCUsesNextLineAsEndAndAppliesOffset() throws {
        let text = """
        [ar:Someone]
        [offset:500]
        [00:10.00]Line one
        [00:12.50][00:20.00]Chorus <00:13.00>word
        [00:15.00]
        """
        let cues = try SubtitleParser.parse(text, format: .lrc)
        XCTAssertEqual(cues.count, 3)
        XCTAssertEqual(cues[0], SubtitleCue(start: 9.5, end: 12, text: "Line one"))
        XCTAssertEqual(cues[1], SubtitleCue(start: 12, end: 14.5, text: "Chorus word"))
        XCTAssertEqual(cues[2].start, 19.5, accuracy: 0.001)
        XCTAssertEqual(cues[2].end, 19.5 + SubtitleParser.lastLyricDuration, accuracy: 0.001)
    }

    func testTextWithoutCuesIsRejected() {
        XCTAssertThrowsError(try SubtitleParser.parse("just some words", format: .srt)) { error in
            XCTAssertEqual(error as? SubtitleParseError, .noCues)
        }
        XCTAssertThrowsError(try SubtitleParser.parse("[ti:Title]\n", format: .lrc))
    }

    func testSRTWriterRoundTrips() throws {
        let cues = [
            SubtitleCue(start: 0.25, end: 2, text: "First."),
            SubtitleCue(start: 3723.457, end: 3725, text: "Much later.")
        ]
        let srt = SubtitleSRTWriter.srt(from: cues)
        XCTAssertTrue(srt.contains("01:02:03,457 --> 01:02:05,000"))
        XCTAssertEqual(try SubtitleParser.parse(srt, format: .srt), cues)
    }

    func testTimestampFormats() {
        XCTAssertEqual(SubtitleParser.timestamp("01:02:03,500"), 3723.5)
        XCTAssertEqual(SubtitleParser.timestamp("02:03.25"), 123.25)
        XCTAssertNil(SubtitleParser.timestamp("ar:Artist"))
        XCTAssertNil(SubtitleParser.timestamp("1e3:00"))
    }

    func testCurrentCueKeepsPreviousDuringPause() {
        let cues = [
            SubtitleCue(start: 1, end: 2, text: "a"),
            SubtitleCue(start: 5, end: 6, text: "b")
        ]
        XCTAssertNil(SubtitleTimeline.cueIndex(at: 0.5, in: cues))
        XCTAssertEqual(SubtitleTimeline.cueIndex(at: 1, in: cues), 0)
        XCTAssertEqual(SubtitleTimeline.cueIndex(at: 3, in: cues), 0)
        XCTAssertEqual(SubtitleTimeline.cueIndex(at: 99, in: cues), 1)
        XCTAssertNil(SubtitleTimeline.cueIndex(at: 1, in: []))
    }

    func testParagraphsBreakAtPausesAndAfterSeveralSentences() {
        let pauseCues = [
            SubtitleCue(start: 0, end: 1, text: "One."),
            SubtitleCue(start: 1.2, end: 2, text: "Two."),
            SubtitleCue(start: 4, end: 5, text: "Three.")
        ]
        XCTAssertEqual(SubtitleTimeline.paragraphs(pauseCues), [0 ..< 2, 2 ..< 3])
        let steady = (0 ..< 9).map { SubtitleCue(start: Double($0), end: Double($0) + 0.9, text: "S.") }
        XCTAssertEqual(SubtitleTimeline.paragraphs(steady), [0 ..< 4, 4 ..< 8, 8 ..< 9])
    }

    func testSourcePriorityPrefersSubtitleFileThenText() {
        var manifest = SubtitleManifest()
        XCTAssertEqual(SubtitleSourcePlanner.availableSources(manifest: manifest, hasScript: false), [])
        manifest.attachedFile = AttachedSubtitleFile(displayName: "a.srt", format: .srt, sha256: "x")
        let available = SubtitleSourcePlanner.availableSources(manifest: manifest, hasScript: true)
        XCTAssertEqual(available, [.subtitleFile, .alignedText])
        XCTAssertEqual(SubtitleSourcePlanner.activeSource(manifest: manifest, available: available), .subtitleFile)
        manifest.selectedSource = .alignedText
        XCTAssertEqual(SubtitleSourcePlanner.activeSource(manifest: manifest, available: available), .alignedText)
        XCTAssertEqual(
            SubtitleSourcePlanner.activeSource(manifest: manifest, available: [.subtitleFile]),
            .subtitleFile
        )
    }
}
