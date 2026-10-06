import SwiftUI

/// The waveform itself: chrome, selection tint and the envelope or bars. It never depends on
/// the playhead, so `.equatable()` keeps SwiftUI from redrawing it on every playhead tick; the
/// played color and the cursor are cheap layers on top (`WaveformPlayedMask`, `WaveformPlayheadLine`).
struct WaveformEnvelopeLayer: View, Equatable {
    let waveform: WaveformPresentation?
    var timedPoints: [TimedWaveformEnvelopePoint] = []
    var assetTimelineStart: TimeInterval = 0
    let viewport: TimelineViewport
    /// Fill of the filled envelope.
    let envelopeColor: Color
    /// Fill of the bars when `barStyle` is set.
    let barColor: Color
    var selection: PracticeRegion?
    var showsChrome = true
    var barStyle: WaveformBarStyle?

    var body: some View {
        #if DEBUG
            let _ = RenderProbe.note("WaveformEnvelopeLayer")
        #endif
        Canvas(rendersAsynchronously: true) { context, size in
            if showsChrome {
                drawBackground(context: context, size: size)
            } else if selection != nil {
                drawSelectionOnly(context: context, size: size)
            }
            drawEnvelope(context: context, size: size)
        }
    }

    private func drawSelectionOnly(context: GraphicsContext, size: CGSize) {
        guard let selection else {
            return
        }
        let startX = xPosition(for: selection.start, width: size.width)
        let endX = xPosition(for: selection.end, width: size.width)
        let rect = CGRect(
            x: max(startX, 0),
            y: 0,
            width: max(min(endX, size.width) - max(startX, 0), 0),
            height: size.height
        )
        context.fill(
            Path(rect),
            with: .color(Color.accentColor.opacity(0.1))
        )
    }

    private func drawBackground(context: GraphicsContext, size: CGSize) {
        let centerY = size.height / 2
        var center = Path()
        center.move(to: CGPoint(x: 0, y: centerY))
        center.addLine(to: CGPoint(x: size.width, y: centerY))
        context.stroke(center, with: .color(.secondary.opacity(0.18)), lineWidth: 1)

        guard let selection else {
            return
        }
        let startX = xPosition(for: selection.start, width: size.width)
        let endX = xPosition(for: selection.end, width: size.width)
        let rect = CGRect(
            x: max(startX, 0),
            y: 0,
            width: max(min(endX, size.width) - max(startX, 0), 0),
            height: size.height
        )
        context.fill(
            Path(rect),
            with: .color(Color.accentColor.opacity(0.1))
        )
    }

    private func drawEnvelope(context: GraphicsContext, size: CGSize) {
        let points = renderablePoints(width: size.width)
        guard !points.isEmpty else {
            return
        }
        let gain = displayGain(for: points)
        if let barStyle {
            drawBars(points: points, gain: gain, style: barStyle, context: context, size: size)
            return
        }
        let centerY = size.height / 2
        let halfHeight = size.height * 0.44
        var path = Path()

        for (index, point) in points.enumerated() {
            let xPosition = xPosition(for: point.time, width: size.width)
            let yPosition = centerY - CGFloat(point.envelope.maximum * gain) * halfHeight
            if index == 0 {
                path.move(to: CGPoint(x: xPosition, y: yPosition))
            } else {
                path.addLine(to: CGPoint(x: xPosition, y: yPosition))
            }
        }
        for point in points.reversed() {
            let xPosition = xPosition(for: point.time, width: size.width)
            let yPosition = centerY - CGFloat(point.envelope.minimum * gain) * halfHeight
            path.addLine(to: CGPoint(x: xPosition, y: yPosition))
        }
        path.closeSubpath()
        context.fill(path, with: .color(envelopeColor))
    }

    private func drawBars(
        points: [TimedWaveformEnvelopePoint],
        gain: Float,
        style: WaveformBarStyle,
        context: GraphicsContext,
        size: CGSize
    ) {
        let samples = points.map { point in
            WaveformBarSample(
                position: xPosition(for: point.time, width: size.width),
                value: CGFloat(min(point.envelope.amplitude * gain, 1))
            )
        }
        let bars = WaveformBarLayout.bars(samples: samples, size: size, style: style, playedX: nil)
        WaveformBarLayout.draw(bars, style: style, context: context, color: barColor, playedColor: nil)
    }

    private func renderablePoints(width: CGFloat) -> [TimedWaveformEnvelopePoint] {
        let targetCount = min(max(Int(width * 2), 1), 4096)
        if !timedPoints.isEmpty {
            let visible = timedPoints.filter { viewport.start ... viewport.end ~= $0.time }
            return aggregate(visible, maximumCount: targetCount)
        }
        guard let waveform else {
            return []
        }
        let slice = WaveformEnvelopeSampler.slice(
            from: waveform,
            assetTimelineStart: assetTimelineStart,
            visibleRange: viewport,
            targetPointCount: targetCount
        )
        guard !slice.points.isEmpty else {
            return []
        }
        return slice.points.enumerated().map { index, envelope in
            let fraction = (Double(index) + 0.5) / Double(slice.points.count)
            return TimedWaveformEnvelopePoint(
                time: slice.timelineStart + slice.timelineDuration * fraction,
                envelope: envelope
            )
        }
    }

    private func aggregate(
        _ points: [TimedWaveformEnvelopePoint],
        maximumCount: Int
    ) -> [TimedWaveformEnvelopePoint] {
        guard maximumCount > 0, points.count > maximumCount else {
            return maximumCount > 0 ? points : []
        }
        return (0 ..< maximumCount).map { index in
            let start = index * points.count / maximumCount
            let end = max((index + 1) * points.count / maximumCount, start + 1)
            let bucket = points[start ..< min(end, points.count)]
            let firstTime = bucket.first?.time ?? 0
            let lastTime = bucket.last?.time ?? firstTime
            return TimedWaveformEnvelopePoint(
                time: (firstTime + lastTime) / 2,
                envelope: WaveformEnvelopePoint(
                    minimum: bucket.map(\.envelope.minimum).min() ?? 0,
                    maximum: bucket.map(\.envelope.maximum).max() ?? 0
                )
            )
        }
    }

    private func displayGain(for points: [TimedWaveformEnvelopePoint]) -> Float {
        let amplitudes = points.map(\.envelope.amplitude).sorted()
        guard !amplitudes.isEmpty else {
            return 1
        }
        let percentileIndex = min(Int(Double(amplitudes.count - 1) * 0.99), amplitudes.count - 1)
        let reference = max(amplitudes[percentileIndex], 0.04)
        return min(0.9 / reference, 12)
    }

    private func xPosition(for time: TimeInterval, width: CGFloat) -> CGFloat {
        guard viewport.duration > 0 else {
            return 0
        }
        return width * CGFloat((time - viewport.start) / viewport.duration)
    }
}

/// Shows the played copy of the waveform only left of the playhead. Bars change color whole
/// (a bar counts as played once the playhead passes its centre), so the edge snaps to the bar grid.
struct WaveformPlayedMask: View {
    let playhead: TimeInterval
    let viewport: TimelineViewport
    var barStyle: WaveformBarStyle?

    var body: some View {
        Canvas { context, size in
            let edge = Self.edge(playhead: playhead, viewport: viewport, width: size.width, barStyle: barStyle)
            context.fill(Path(CGRect(x: 0, y: 0, width: edge, height: size.height)), with: .color(.black))
        }
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

/// The thin cursor line at the playhead.
struct WaveformPlayheadLine: View {
    let playhead: TimeInterval
    let viewport: TimelineViewport
    let style: WaveformPlayheadStyle

    var body: some View {
        Canvas { context, size in
            guard viewport.contains(playhead), viewport.duration > 0 else {
                return
            }
            let xPosition = size.width * CGFloat((playhead - viewport.start) / viewport.duration)
            var cursor = Path()
            cursor.move(to: CGPoint(x: xPosition, y: 0))
            cursor.addLine(to: CGPoint(x: xPosition, y: size.height))
            context.stroke(cursor, with: .color(style.color), lineWidth: style.width)
        }
    }
}
