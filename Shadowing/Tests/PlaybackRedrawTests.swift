import AppKit
import Combine
import Observation
@testable import Shadowing
import SwiftUI
import XCTest

/// Playback ticks must not redraw the practice screen: only the playhead clock changes per
/// tick, the main view model publishes only when the sentence changes, and the time label keeps
/// one width.
@MainActor
final class PlaybackRedrawTests: XCTestCase {
    /// 0.15 s sentences over the 30 s fixture source.
    private let cues = (0 ..< 200).map { index in
        SubtitleCue(
            start: Double(index) * 0.15,
            end: Double(index) * 0.15 + 0.1,
            text: "Sentence number \(index) of the practice transcript, long enough to wrap."
        )
    }

    private func playingFixture() async throws -> M9Fixture {
        let fixture = try await M9TestSupport.makeFixture(testCase: self, selectRegion: false)
        let model = fixture.viewModel
        await M9TestSupport.waitUntil { model.revealToken > 0 }
        model.subtitles.display = .timed(SubtitleTranscript(cues: cues))
        model.togglePlayback()
        await M9TestSupport.waitUntil { model.isPlaying }
        await fixture.audio.emit(.playheadChanged(15.01))
        await M9TestSupport.waitUntil { abs(model.playhead - 15.01) < 1e-9 }
        return fixture
    }

    func testTicksInsideOneSentencePublishNothingAndABoundaryPublishesOnce() async throws {
        let fixture = try await playingFixture()
        let model = fixture.viewModel
        XCTAssertEqual(model.currentSentenceIndex, 100)
        let modelChanges = PublisherCounter(model.objectWillChange)
        var sentences: [Int?] = []
        let sentenceSubscription = model.$playheadSentence.dropFirst().sink { sentences.append($0.cueIndex) }

        for tick in 1 ... 30 {
            await fixture.audio.emit(.playheadChanged(15.01 + Double(tick) * 0.003))
        }
        await M9TestSupport.waitUntil { abs(model.playhead - 15.1) < 1e-9 }
        XCTAssertEqual(model.playheadClock.position, model.playhead, accuracy: 1e-9, "the clock still moves")
        XCTAssertEqual(modelChanges.count, 0, "ticks inside a sentence leave the main view model alone")
        XCTAssertTrue(sentences.isEmpty)

        await fixture.audio.emit(.playheadChanged(15.16))
        await M9TestSupport.waitUntil { model.currentSentenceIndex == 101 }
        XCTAssertEqual(sentences, [101], "crossing into the next sentence publishes exactly once")
        XCTAssertEqual(modelChanges.count, 1)
        sentenceSubscription.cancel()
    }

    func testTimeLabelKeepsOneWidthWhileTheTimeRuns() {
        let duration: TimeInterval = 129 // 2:09
        let widths = [9.0, 71, 129].map { position in
            let label = PlayheadTimeLabel(clock: PlayheadClock(position: position), duration: duration)
            return NSHostingView(rootView: label).fittingSize.width
        }
        XCTAssertEqual(PlayheadTimeLabel.text(position: 71, duration: duration), "1:11 / 2:09")
        XCTAssertGreaterThan(widths[0], 0)
        XCTAssertEqual(widths[0], widths[1], accuracy: 0.01)
        XCTAssertEqual(widths[1], widths[2], accuracy: 0.01)
    }

    /// The real practice screen with the transcript open: per playback tick inside a sentence
    /// none of the views watching the view model re-evaluate, the waveform tracks and bars are
    /// not redrawn, only the playhead masks update, and the window is never laid out again
    /// (each layout pass recomputed `NSHostingView.minSize`, ~10% of the main thread).
    func testPlaybackTicksRedrawOnlyThePlayheadViews() async throws {
        let key = SubtitlePreferences.transcriptKey
        UserDefaults.standard.set(true, forKey: key)
        defer { UserDefaults.standard.removeObject(forKey: key) }
        let fixture = try await playingFixture()
        let model = fixture.viewModel
        let size = CGSize(width: 1300, height: 820)
        let hosting = LayoutCountingHostingView(
            rootView: NavigationStack { PracticeView(viewModel: model) }.frame(width: size.width, height: size.height)
        )
        hosting.frame = CGRect(origin: .zero, size: size)
        let window = NSWindow(
            contentRect: CGRect(origin: CGPoint(x: -20000, y: -20000), size: size),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        window.orderFrontRegardless()
        defer {
            window.orderOut(nil)
            window.close()
        }
        try await Task.sleep(for: .milliseconds(500))
        RenderProbe.counts = [:]
        hosting.layoutPasses = 0
        for tick in 1 ... 30 {
            await fixture.audio.emit(.playheadChanged(15.01 + Double(tick) * 0.003))
            try await Task.sleep(for: .milliseconds(20))
        }
        let counts = RenderProbe.counts
        print("Redraws over 30 ticks inside one sentence: \(counts.sorted { $0.key < $1.key })")
        for name in [
            "PracticeView", "OriginalWaveformSection", "CompareBar", "TakesListSection",
            "PracticeControlBar", "PracticeTransportControls", "SubtitlesInspector",
            "SubtitleTranscriptView", "TranscriptSentenceRow", "WaveformEnvelopeLayer", "WaveformTimelineTrack"
        ] {
            XCTAssertEqual(counts[name, default: 0], 0, "\(name) must not redraw per tick")
        }
        XCTAssertGreaterThan(counts["WaveformPlayedMask", default: 0], 0, "the played color still follows the playhead")
        XCTAssertLessThanOrEqual(hosting.layoutPasses, 3, "playback ticks must not lay out the window")
    }

    /// The time label shows whole seconds, so ticks inside one second must not touch it.
    func testClockNotifiesTheTimeLabelOnlyWhenTheSecondChanges() {
        let clock = PlayheadClock(position: 3.2)
        let notified = ObservationFlag()
        withObservationTracking {
            _ = clock.wholeSecond
        } onChange: {
            notified.isSet = true
        }
        clock.position = 3.5
        clock.position = 3.98
        XCTAssertFalse(notified.isSet, "ticks inside 0:03 leave the label alone")
        XCTAssertEqual(clock.wholeSecond, 3)
        clock.position = 4.01
        XCTAssertTrue(notified.isSet)
        XCTAssertEqual(clock.wholeSecond, 4)
        XCTAssertEqual(PlayheadClock.wholeSecond(of: 2.9999999), 3, "floors like ClockText, float noise included")
        XCTAssertEqual(PlayheadClock.wholeSecond(of: -1), 0)
    }

    /// The played copy of the bars is masked at `playedEdge`: every bar `bars(playedX:)` marks
    /// played lies inside the mask, every other bar outside it.
    func testPlayedMaskEdgeColorsExactlyThePlayedBars() {
        let size = CGSize(width: 300, height: 40)
        let samples = stride(from: CGFloat(0), to: size.width, by: 0.5).map {
            WaveformBarSample(position: $0, value: 0.5)
        }
        for style in [WaveformBarStyle.original, .mini] {
            for playedX in stride(from: CGFloat(-2), through: size.width + 2, by: 0.37) {
                let edge = WaveformBarLayout.playedEdge(playedX: playedX, style: style, width: size.width)
                for bar in WaveformBarLayout.bars(samples: samples, size: size, style: style, playedX: playedX) {
                    if bar.isPlayed {
                        XCTAssertLessThanOrEqual(bar.rect.maxX, edge + 1e-6, "played bar at \(bar.rect.minX) cut off")
                    } else {
                        XCTAssertGreaterThanOrEqual(bar.rect.minX, edge - 1e-6, "bar at \(bar.rect.minX) colored")
                    }
                }
            }
        }
        let viewport = TimelineViewport(start: 10, duration: 20, sourceDuration: 60)
        XCTAssertEqual(WaveformPlayedMask.edge(playhead: 20, viewport: viewport, width: 200, barStyle: nil), 100)
        XCTAssertEqual(WaveformPlayedMask.edge(playhead: 5, viewport: viewport, width: 200, barStyle: nil), 0)
        XCTAssertEqual(WaveformPlayedMask.edge(playhead: 50, viewport: viewport, width: 200, barStyle: nil), 200)
    }
}

/// Set from an observation callback (which runs synchronously on the mutating thread here).
private final class ObservationFlag: @unchecked Sendable {
    var isSet = false
}

/// Counts the window's constraint passes (each one recomputes the hosting view's minimum size).
private final class LayoutCountingHostingView<Content: View>: NSHostingView<Content> {
    var layoutPasses = 0

    override func updateConstraints() {
        layoutPasses += 1
        super.updateConstraints()
    }
}

/// Counts emissions of a publisher while alive.
private final class PublisherCounter {
    private(set) var count = 0
    private var subscription: AnyCancellable?

    init(_ publisher: ObservableObjectPublisher) {
        subscription = publisher.sink { [weak self] _ in self?.count += 1 }
    }
}
