import Observation
import SwiftUI

/// The live playhead, which changes many times a second while playing. Only the time label
/// and the waveform cursors read it, so a tick redraws just those few views.
///
/// It used to be a published field of `PracticeViewModel`: every tick then re-evaluated every
/// view watching the view model (waveforms, takes list, Compare bar, control bar, transcript)
/// and re-measured the whole window for its minimum size (~85% CPU while playing).
@MainActor
@Observable
final class PlayheadClock {
    var position: TimeInterval

    init(position: TimeInterval) {
        self.position = position
    }
}

/// Reads the live playhead for its content only; the parent never observes the tick.
struct PlayheadReader<Content: View>: View {
    let clock: PlayheadClock
    @ViewBuilder let content: (TimeInterval) -> Content

    var body: some View {
        content(clock.position)
    }
}

/// "1:02 / 2:09" in monospaced digits, in a width reserved from the duration's digit count, so
/// its size never changes while the time runs and nothing above it is re-measured.
struct PlayheadTimeLabel: View {
    let clock: PlayheadClock
    let duration: TimeInterval

    var body: some View {
        ZStack(alignment: .leading) {
            Text(verbatim: Self.widthTemplate(duration: duration))
                .hidden()
            Text(verbatim: Self.text(position: clock.position, duration: duration))
        }
        .font(Self.font)
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .fixedSize()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Playback position")
        .accessibilityValue(Text(verbatim: Self.text(position: clock.position, duration: duration)))
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

/// What the views show for "the current sentence". Changes only when the playhead crosses into
/// another sentence, so playback ticks inside a sentence publish nothing.
struct PlayheadSentence: Equatable, Sendable {
    var cueIndex: Int?
    var sentence: SentenceChunk?
}
