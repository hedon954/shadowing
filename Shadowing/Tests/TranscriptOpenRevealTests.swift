import AppKit
@testable import Shadowing
import SwiftUI
import XCTest

/// Opening a project or any active jump, also while paused, scrolls the full transcript to the
/// sentence under the playhead (about a third from the top) and highlights it.
@MainActor
final class TranscriptOpenRevealTests: XCTestCase {
    /// 40 sentences over the 30 s fixture source, with a gap after each one.
    private let cues = (0 ..< 40).map { index in
        SubtitleCue(
            start: Double(index) * 0.75,
            end: Double(index) * 0.75 + 0.5,
            text: "Sentence number \(index) of the practice transcript."
        )
    }

    func testRevealIndexIsTheSentenceUnderThePlayheadOrNearestEarlier() {
        let index = SubtitleTimeline.cueIndex(at: 13.1, in: cues)
        XCTAssertEqual(SubtitleTimeline.revealIndex(current: index, cueCount: cues.count), 17)
        XCTAssertEqual(SubtitleTimeline.revealIndex(current: nil, cueCount: cues.count), 0, "before the first cue")
        XCTAssertEqual(SubtitleTimeline.revealIndex(current: 99, cueCount: cues.count), 39, "never past the end")
        XCTAssertNil(SubtitleTimeline.revealIndex(current: nil, cueCount: 0))
    }

    func testOpeningProjectWhilePausedRevealsTheSentenceUnderThePlayhead() async throws {
        let fixture = try await M9TestSupport.makeFixture(
            testCase: self,
            selectRegion: false,
            restoredPlayhead: 22.7 // in the gap after sentence 30 (22.5 ..< 23.0 is 30)
        )
        let model = fixture.viewModel
        await M9TestSupport.waitUntil { model.revealToken > 0 }
        model.subtitles.display = .timed(SubtitleTranscript(cues: cues))
        XCTAssertFalse(model.isPlaying)
        XCTAssertEqual(model.currentCueIndex, 30)
        XCTAssertEqual(model.transcriptRevealIndex, 30)
    }

    func testTakeClickWhilePausedRevealsTheTakeSentence() async throws {
        let fixture = try await M9TestSupport.makeFixtureWithCommittedTake(testCase: self)
        let model = fixture.viewModel
        let take = try XCTUnwrap(model.takes.first)
        model.subtitles.display = .timed(SubtitleTranscript(cues: cues))
        model.seek(to: 28)
        XCTAssertFalse(model.isPlaying)
        let token = model.revealToken

        model.selectTake(take)
        XCTAssertFalse(model.isPlaying)
        XCTAssertEqual(model.revealToken, token + 1, "a take click is an active jump")
        let expected = SubtitleTimeline.cueIndex(at: take.region.start, in: cues)
        XCTAssertEqual(model.currentCueIndex, expected)
        XCTAssertEqual(model.transcriptRevealIndex, expected)
    }

    func testPausedPlayheadEventsMoveTheCurrentSentence() async throws {
        let fixture = try await M9TestSupport.makeFixture(testCase: self, selectRegion: false)
        let model = fixture.viewModel
        await M9TestSupport.waitUntil { model.revealToken > 0 } // restored session applied
        model.subtitles.display = .timed(SubtitleTranscript(cues: cues))
        await fixture.audio.emit(.playheadChanged(9.1))
        await M9TestSupport.waitUntil { model.currentCueIndex == 12 }
        XCTAssertFalse(model.isPlaying)
    }

    func testScrollIDsAreUniqueAndTyped() {
        let transcript = SubtitleTranscript(cues: cues)
        let ids = transcript.scrollIDs
        XCTAssertEqual(Set(ids).count, ids.count, "no two rows share a scroll id")
        XCTAssertEqual(ids.compactMap(\.sentenceIndex), Array(cues.indices))
        XCTAssertGreaterThan(transcript.paragraphs.count, 8, "paragraph indices overlap sentence indices")
        XCTAssertNotEqual(TranscriptRowID.paragraph(8), TranscriptRowID.sentence(8))
    }

    /// Real window: the highlighted band of a sentence far down the list ends up on screen,
    /// in the upper half, instead of the panel showing the end (or the start) of the list.
    func testAppearingScrollsTheCurrentSentenceIntoTheUpperThird() async throws {
        let middle = try await renderedBandMiddle(current: 17)
        XCTAssertGreaterThan(middle, 0.1)
        XCTAssertLessThan(middle, 0.6, "the current sentence sits about a third from the top")
    }

    /// Sentence 8 shares its number with paragraph 8 near the end. Opening twice in a row
    /// must land on the sentence both times.
    func testSentenceWhoseIndexIsAlsoAParagraphIndexLandsOnTheSentenceEveryOpen() async throws {
        for _ in 0 ..< 2 {
            let middle = try await renderedBandMiddle(current: 8)
            XCTAssertGreaterThan(middle, 0.1)
            XCTAssertLessThan(middle, 0.6, "the current sentence sits about a third from the top")
        }
    }

    /// Opens the transcript in a fresh off-screen window and returns where the current band's
    /// middle is, as a fraction of the height from the top.
    private func renderedBandMiddle(current: Int) async throws -> Double {
        let size = CGSize(width: 300, height: 240)
        let view = SubtitleTranscriptView(
            transcript: SubtitleTranscript(cues: cues),
            current: current,
            revealToken: 1,
            autoFollows: { true },
            onUserScroll: {},
            onSeek: { _ in }
        )
        .frame(width: size.width, height: size.height)
        .background(Color(nsColor: .windowBackgroundColor))
        let hosting = NSHostingView(rootView: view)
        hosting.frame = CGRect(origin: .zero, size: size)
        let window = NSWindow(
            contentRect: CGRect(origin: CGPoint(x: -20000, y: -20000), size: size),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .aqua)
        window.contentView = hosting
        window.orderFrontRegardless()
        defer {
            window.orderOut(nil)
            window.close()
        }
        try await Task.sleep(for: .milliseconds(400))
        hosting.layoutSubtreeIfNeeded()
        let rep = try XCTUnwrap(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        let rows = try XCTUnwrap(Self.accentRows(in: XCTUnwrap(rep.cgImage)), "the current band is visible")
        return Double(rows.lowerBound + rows.upperBound) / 2 / Double(rep.pixelsHigh)
    }

    /// Top and bottom pixel rows of the accent-tinted band (blue clearly above red).
    private static func accentRows(in image: CGImage) throws -> ClosedRange<Int>? {
        let width = image.width, height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let context = try XCTUnwrap(
            CGContext(
                data: &pixels,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
        )
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        var tinted: [Int] = []
        for row in 0 ..< height {
            var count = 0
            for column in stride(from: 0, to: width, by: 2) {
                let offset = (row * width + column) * 4
                if Int(pixels[offset + 2]) - Int(pixels[offset]) > 20 {
                    count += 1
                }
            }
            if count > width / 8 {
                tinted.append(row)
            }
        }
        guard let first = tinted.first, let last = tinted.last else {
            return nil
        }
        return first ... last
    }
}
