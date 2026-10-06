import SwiftUI

/// Playhead line drawn over a waveform track.
struct WaveformPlayheadStyle: Equatable {
    var color: Color
    var width: CGFloat

    static let standard = WaveformPlayheadStyle(color: .primary.opacity(0.65), width: 1)
}

/// A waveform with an optional played color and playhead cursor. The waveform is drawn once
/// (`WaveformEnvelopeLayer`); a playhead tick only moves the played mask and the cursor, which
/// read the clock inside a mask (`playheadMask`), so the track itself is never re-evaluated.
struct WaveformTimelineTrack: View {
    let waveform: WaveformPresentation?
    var timedPoints: [TimedWaveformEnvelopePoint] = []
    var assetTimelineStart: TimeInterval = 0
    let viewport: TimelineViewport
    let color: Color
    var playhead: TimeInterval?
    /// The live playhead. When set it replaces `playhead`, and only the played mask and the
    /// cursor read it, so a tick never re-evaluates (or re-lays-out) the track itself.
    var clock: PlayheadClock?
    var selection: PracticeRegion?
    var emphasized = true
    /// When false, draws only the envelope/playhead so layers can stack (overview).
    var showsChrome = true
    /// When set, the part before the playhead uses this color and the rest uses `color`.
    var playedColor: Color?
    var playheadStyle = WaveformPlayheadStyle.standard
    /// When set, draws discrete mirrored bars instead of a filled envelope.
    var barStyle: WaveformBarStyle?

    var body: some View {
        #if DEBUG
            let _ = RenderProbe.note("WaveformTimelineTrack")
        #endif
        ZStack {
            WaveformEnvelopeLayer(
                waveform: waveform,
                timedPoints: timedPoints,
                assetTimelineStart: assetTimelineStart,
                viewport: viewport,
                envelopeColor: envelopeColor,
                barColor: barColor,
                selection: selection,
                showsChrome: showsChrome,
                barStyle: barStyle
            )
            .equatable()
            if let playedColor, hasPlayhead {
                WaveformEnvelopeLayer(
                    waveform: waveform,
                    timedPoints: timedPoints,
                    assetTimelineStart: assetTimelineStart,
                    viewport: viewport,
                    envelopeColor: playedColor,
                    barColor: playedColor,
                    showsChrome: false,
                    barStyle: barStyle
                )
                .equatable()
                .playheadMask(fixed: playhead, clock: clock) { position, width in
                    WaveformPlayedMask(playhead: position, viewport: viewport, width: width, barStyle: barStyle)
                }
            }
        }
        .overlay {
            if hasPlayhead, playheadStyle.width > 0 {
                Rectangle()
                    .fill(playheadStyle.color)
                    .playheadMask(fixed: playhead, clock: clock) { position, width in
                        WaveformPlayheadLine(
                            playhead: position,
                            viewport: viewport,
                            trackWidth: width,
                            lineWidth: playheadStyle.width
                        )
                    }
                    .allowsHitTesting(false)
            }
        }
        .background {
            if showsChrome {
                Color(nsColor: .controlBackgroundColor)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: showsChrome ? 8 : 0))
        .accessibilityHidden(true)
    }

    /// Unplayed envelope: full color under a played copy, otherwise dimmed by emphasis.
    private var envelopeColor: Color {
        playedColor != nil && hasPlayhead ? color : color.opacity(emphasized ? 0.82 : 0.3)
    }

    private var hasPlayhead: Bool {
        clock != nil || playhead != nil
    }

    private var barColor: Color {
        playedColor == nil ? color.opacity(emphasized ? 1 : 0.3) : color
    }
}
