import SwiftUI

/// Playhead line drawn over a waveform track.
struct WaveformPlayheadStyle: Equatable {
    var color: Color
    var width: CGFloat

    static let standard = WaveformPlayheadStyle(color: .primary.opacity(0.65), width: 1)
}

/// A waveform with an optional played color and playhead cursor. The waveform is drawn once
/// (`WaveformEnvelopeLayer`); a playhead tick only moves the played mask and the cursor.
struct WaveformTimelineTrack: View {
    let waveform: WaveformPresentation?
    var timedPoints: [TimedWaveformEnvelopePoint] = []
    var assetTimelineStart: TimeInterval = 0
    let viewport: TimelineViewport
    let color: Color
    var playhead: TimeInterval?
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
            if let playedColor, let playhead {
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
                .mask {
                    WaveformPlayedMask(playhead: playhead, viewport: viewport, barStyle: barStyle)
                }
            }
            if let playhead, playheadStyle.width > 0 {
                WaveformPlayheadLine(playhead: playhead, viewport: viewport, style: playheadStyle)
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
        playedColor != nil && playhead != nil ? color : color.opacity(emphasized ? 0.82 : 0.3)
    }

    private var barColor: Color {
        playedColor == nil ? color.opacity(emphasized ? 1 : 0.3) : color
    }
}
