import Observation
import SwiftUI

/// The live playhead, which changes many times a second while playing. Only the time label
/// (once a second, via `wholeSecond`) and the waveform's playhead masks read it, so a tick
/// redraws just those few layers and never lays out the window.
///
/// It used to be a published field of `PracticeViewModel`: every tick then re-evaluated every
/// view watching the view model (waveforms, takes list, Compare bar, control bar, transcript)
/// and re-measured the whole window for its minimum size (~85% CPU while playing).
@MainActor
@Observable
final class PlayheadClock {
    var position: TimeInterval {
        didSet {
            let second = Self.wholeSecond(of: position)
            if second != wholeSecond {
                wholeSecond = second
            }
        }
    }

    /// The whole second the time label shows. Written only when it changes, so the label
    /// re-evaluates once a second instead of on every tick.
    private(set) var wholeSecond: Int

    init(position: TimeInterval) {
        self.position = position
        wholeSecond = Self.wholeSecond(of: position)
    }

    /// Floors like `ClockText.format`, so the label reads exactly what it would from `position`.
    nonisolated static func wholeSecond(of time: TimeInterval) -> Int {
        time.isFinite ? max(Int((time + 0.001).rounded(.down)), 0) : 0
    }
}

/// "1:02 / 2:09" in monospaced digits, in a width reserved from the duration's digit count, so
/// its size never changes while the time runs and nothing above it is re-measured.
struct PlayheadTimeLabel: View {
    let clock: PlayheadClock
    let duration: TimeInterval

    var body: some View {
        // The template alone sizes the label. The live text is an overlay, which never feeds
        // into its parent's size, so a tick changes pixels only and nothing is re-measured.
        Text(verbatim: Self.widthTemplate(duration: duration))
            .hidden()
            .overlay(alignment: .leading) {
                PlayheadTimeText(clock: clock, duration: duration)
            }
            .font(Self.font)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .fixedSize()
    }

    static let font = Font.system(size: 12).monospacedDigit()

    static func text(position: TimeInterval, duration: TimeInterval) -> String {
        ClockText.format(min(max(position, 0), duration)) + " / " + ClockText.format(duration)
    }

    /// The widest the label gets for this duration: every digit an 8 (digits are monospaced).
    static func widthTemplate(duration: TimeInterval) -> String {
        let total = ClockText.format(duration)
        let digits = String(total.map { $0.isNumber ? "8" : $0 })
        return digits + " / " + digits
    }
}

/// The ticking part of `PlayheadTimeLabel`: only this view reads the clock.
private struct PlayheadTimeText: View {
    let clock: PlayheadClock
    let duration: TimeInterval

    var body: some View {
        let text = PlayheadTimeLabel.text(position: TimeInterval(clock.wholeSecond), duration: duration)
        Text(verbatim: text)
            .fixedSize()
            .accessibilityLabel("Playback position")
            .accessibilityValue(Text(verbatim: text))
    }
}

/// What the views show for "the current sentence". Changes only when the playhead crosses into
/// another sentence, so playback ticks inside a sentence publish nothing.
struct PlayheadSentence: Equatable, Sendable {
    var cueIndex: Int?
    var sentence: SentenceChunk?
}
