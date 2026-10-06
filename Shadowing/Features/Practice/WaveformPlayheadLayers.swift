import SwiftUI

// The moving parts of the waveform card: the played color and the playhead cursors.
//
// Each is a mask over a static colored layer, and only the mask reads the clock. SwiftUI
// redraws a changed mask without measuring anything, so a playhead tick never reaches the
// window's layout. Measured in a real window, reading the clock anywhere else (even in an
// overlay or a background, even with a render-only offset) made AppKit recompute the window's
// minimum size on every tick. Positions are snapped to whole pixels (and the played edge to the
// bar grid), so a tick that wouldn't change any pixel changes no value and redraws nothing.

extension View {
    /// Masks this view with a shape built from the playhead and the view's width. The clock is
    /// read only inside the mask; see the note at the top of this file.
    func playheadMask(
        fixed: TimeInterval?,
        clock: PlayheadClock?,
        @ViewBuilder _ mask: @escaping (_ playhead: TimeInterval, _ width: CGFloat) -> some View
    ) -> some View {
        self.mask {
            GeometryReader { proxy in
                TrackPlayheadReader(fixed: fixed, clock: clock) { position in
                    mask(position, proxy.size.width)
                }
            }
        }
    }
}

/// Reads the playhead for one moving layer: the live clock when given (so only this layer
/// re-evaluates on a tick), otherwise a fixed value.
struct TrackPlayheadReader<Content: View>: View {
    let fixed: TimeInterval?
    let clock: PlayheadClock?
    @ViewBuilder let content: (TimeInterval) -> Content

    var body: some View {
        if let clock {
            content(clock.position)
        } else if let fixed {
            content(fixed)
        }
    }
}

enum PixelGrid {
    static func align(_ value: CGFloat, scale: CGFloat) -> CGFloat {
        guard scale > 0 else {
            return value
        }
        return (value * scale).rounded() / scale
    }
}

/// Shows the played copy of the waveform only left of the playhead: a full-width strip slid
/// left so its right edge sits at the playhead. Bars change color whole (a bar counts as played
/// once the playhead passes its centre), so the edge snaps to the bar grid.
struct WaveformPlayedMask: View {
    let playhead: TimeInterval
    let viewport: TimelineViewport
    let width: CGFloat
    var barStyle: WaveformBarStyle?

    @Environment(\.displayScale) private var displayScale

    var body: some View {
        #if DEBUG
            let _ = RenderProbe.note("WaveformPlayedMask")
        #endif
        let edge = PixelGrid.align(
            Self.edge(playhead: playhead, viewport: viewport, width: width, barStyle: barStyle),
            scale: displayScale
        )
        Rectangle()
            .fill(.black)
            .offset(x: edge - width)
    }

    static func edge(
        playhead: TimeInterval,
        viewport: TimelineViewport,
        width: CGFloat,
        barStyle: WaveformBarStyle?
    ) -> CGFloat {
        guard viewport.duration > 0 else {
            return 0
        }
        let playedX = width * CGFloat((playhead - viewport.start) / viewport.duration)
        guard let barStyle else {
            return min(max(playedX, 0), width)
        }
        return WaveformBarLayout.playedEdge(playedX: playedX, style: barStyle, width: width)
    }
}

/// The thin cursor line at the playhead (drawn black: it is a mask). Fixed width, moved with
/// `.offset` only, hidden when the playhead is outside the visible window.
struct WaveformPlayheadLine: View {
    let playhead: TimeInterval
    let viewport: TimelineViewport
    let trackWidth: CGFloat
    let lineWidth: CGFloat

    @Environment(\.displayScale) private var displayScale

    var body: some View {
        let xPosition = Self.xPosition(playhead: playhead, viewport: viewport, width: trackWidth)
        Rectangle()
            .fill(.black)
            .frame(width: lineWidth)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .offset(x: PixelGrid.align((xPosition ?? 0) - lineWidth / 2, scale: displayScale))
            .opacity(xPosition == nil ? 0 : 1)
    }

    /// Where the cursor sits, or nil when the playhead is outside the visible window.
    static func xPosition(playhead: TimeInterval, viewport: TimelineViewport, width: CGFloat) -> CGFloat? {
        guard viewport.contains(playhead), viewport.duration > 0 else {
            return nil
        }
        return width * CGFloat((playhead - viewport.start) / viewport.duration)
    }
}

/// The playhead line through both lanes of the card (drawn black: it is a mask), offset by the
/// label column like the rest of `SentenceBandOverlay`.
struct SentencePlayheadCursor: View {
    let playhead: TimeInterval
    let viewport: TimelineViewport
    let leading: CGFloat
    let width: CGFloat

    static let lineWidth: CGFloat = 2

    @Environment(\.displayScale) private var displayScale

    var body: some View {
        let visible = viewport.contains(playhead)
        let laneWidth = max(width - leading, 1)
        let xPosition = leading + SentenceBandOverlay.x(for: playhead, viewport: viewport, width: laneWidth)
        RoundedRectangle(cornerRadius: 1)
            .fill(.black)
            .frame(width: Self.lineWidth)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .offset(x: visible ? PixelGrid.align(xPosition - Self.lineWidth / 2, scale: displayScale) : 0)
            .opacity(visible ? 1 : 0)
    }
}
