import SwiftUI

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

    var body: some View {
        Canvas(rendersAsynchronously: true) { context, size in
            if showsChrome {
                drawBackground(context: context, size: size)
            } else if selection != nil {
                drawSelectionOnly(context: context, size: size)
            }
            drawEnvelope(context: context, size: size)
            drawPlayhead(context: context, size: size)
        }
        .background {
            if showsChrome {
                Color(nsColor: .controlBackgroundColor)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: showsChrome ? 8 : 0))
        .accessibilityHidden(true)
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
        context.fill(
            path,
            with: .color(color.opacity(emphasized ? 0.82 : 0.3))
        )
    }

    private func drawPlayhead(context: GraphicsContext, size: CGSize) {
        guard let playhead, viewport.contains(playhead) else {
            return
        }
        let xPosition = xPosition(for: playhead, width: size.width)
        var cursor = Path()
        cursor.move(to: CGPoint(x: xPosition, y: 0))
        cursor.addLine(to: CGPoint(x: xPosition, y: size.height))
        context.stroke(cursor, with: .color(.primary.opacity(0.65)), lineWidth: 1)
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

struct WaveformTimelineOverview: View {
    private static let edgeHandleWidth: CGFloat = 12
    private static let edgeHitWidth: CGFloat = 14

    private enum DragKind {
        case pan(grabOffset: TimeInterval)
        case resize(TimelineViewport.Edge)
    }

    struct TakeThumbnail: Equatable, Identifiable {
        let id: UUID
        let waveform: WaveformPresentation
        let timelineStart: TimeInterval
        let isSelected: Bool
    }

    let waveform: WaveformPresentation
    var takeThumbnails: [TakeThumbnail] = []
    let sourceDuration: TimeInterval
    let viewport: TimelineViewport
    let region: PracticeRegion?
    let playhead: TimeInterval
    let isInteractive: Bool
    let onViewportChanged: (TimelineViewport) -> Void
    var onBackgroundTap: (() -> Void)?

    @State private var dragKind: DragKind?
    @State private var dragOrigin: TimelineViewport?
    /// Local viewport while dragging so the blue window tracks the pointer
    /// without waiting on the parent Canvas redraw cycle.
    @State private var liveViewport: TimelineViewport?
    @State private var dragBeganOutsideWindow = false

    private var displayedViewport: TimelineViewport {
        liveViewport ?? viewport
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                WaveformTimelineTrack(
                    waveform: waveform,
                    viewport: .full(sourceDuration: sourceDuration),
                    color: .secondary,
                    playhead: nil,
                    selection: region,
                    emphasized: true,
                    showsChrome: false
                )
                ForEach(takeThumbnails) { thumbnail in
                    WaveformTimelineTrack(
                        waveform: thumbnail.waveform,
                        assetTimelineStart: thumbnail.timelineStart,
                        viewport: .full(sourceDuration: sourceDuration),
                        color: .orange,
                        playhead: nil,
                        selection: nil,
                        emphasized: thumbnail.isSelected,
                        showsChrome: false
                    )
                    .opacity(thumbnail.isSelected ? 0.9 : 0.55)
                    .allowsHitTesting(false)
                }
                WaveformTimelineTrack(
                    waveform: nil,
                    viewport: .full(sourceDuration: sourceDuration),
                    color: .clear,
                    playhead: playhead,
                    selection: nil,
                    showsChrome: false
                )
                .allowsHitTesting(false)
                visibleWindow(size: geometry.size, viewport: displayedViewport)
                interactionLayer(size: geometry.size)
            }
            .background(
                Color(nsColor: .controlBackgroundColor),
                in: RoundedRectangle(cornerRadius: 8)
            )
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .coordinateSpace(name: "overviewTimeline")
        }
        .frame(height: 58)
        .accessibilityElement()
        .accessibilityLabel("Full audio waveform overview")
        .accessibilityValue(
            "Visible from \(format(displayedViewport.start)) to \(format(displayedViewport.end))"
        )
        .accessibilityHint(
            "Drag the highlighted window to pan, or drag its borders to zoom the detailed timeline."
        )
        .accessibilityAdjustableAction { direction in
            guard isInteractive else {
                return
            }
            let fraction = direction == .increment ? 0.25 : -0.25
            onViewportChanged(
                viewport.panned(
                    by: viewport.duration * fraction,
                    sourceDuration: sourceDuration
                )
            )
        }
    }

    private func visibleWindow(size: CGSize, viewport: TimelineViewport) -> some View {
        let width = sourceDuration > 0
            ? size.width * CGFloat(viewport.duration / sourceDuration)
            : size.width
        let clampedWidth = max(width, 3)
        let centerX = sourceDuration > 0
            ? size.width * CGFloat((viewport.start + viewport.duration / 2) / sourceDuration)
            : size.width / 2
        return ZStack {
            RoundedRectangle(cornerRadius: 5)
                .fill(Color.accentColor.opacity(0.08))
                .overlay {
                    RoundedRectangle(cornerRadius: 5)
                        .stroke(Color.accentColor, lineWidth: 2)
                }

            edgeAffordance(alignment: .leading, windowWidth: clampedWidth)
            edgeAffordance(alignment: .trailing, windowWidth: clampedWidth)
        }
        .frame(width: clampedWidth, height: size.height)
        .position(x: centerX, y: size.height / 2)
        .allowsHitTesting(false)
    }

    private func edgeAffordance(alignment: Alignment, windowWidth: CGFloat) -> some View {
        let handleWidth = min(Self.edgeHandleWidth, max(windowWidth / 2, 3))
        return HStack(spacing: 0) {
            if alignment == .trailing {
                Spacer(minLength: 0)
            }
            Capsule()
                .fill(Color.accentColor.opacity(0.85))
                .frame(width: 3, height: 22)
                .frame(width: handleWidth, height: .infinity)
            if alignment == .leading {
                Spacer(minLength: 0)
            }
        }
        .accessibilityHidden(true)
    }

    private func interactionLayer(size: CGSize) -> some View {
        Color.clear
            .contentShape(Rectangle())
            .gesture(overviewDragGesture(containerWidth: size.width))
            .allowsHitTesting(isInteractive)
    }

    private func overviewDragGesture(containerWidth: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named("overviewTimeline"))
            .onChanged { value in
                guard isInteractive, containerWidth > 0, sourceDuration > 0 else {
                    return
                }
                if dragKind == nil {
                    beginDrag(
                        at: value.startLocation.x,
                        containerWidth: containerWidth
                    )
                }
                guard let dragKind, let dragOrigin else {
                    return
                }
                let time = time(
                    at: value.location.x,
                    containerWidth: containerWidth
                )
                let next: TimelineViewport = switch dragKind {
                case let .pan(grabOffset):
                    TimelineViewport(
                        start: time - grabOffset,
                        duration: dragOrigin.duration,
                        sourceDuration: sourceDuration
                    )
                case let .resize(edge):
                    dragOrigin.resizing(
                        edge: edge,
                        to: time,
                        sourceDuration: sourceDuration
                    )
                }
                guard next != liveViewport else {
                    return
                }
                liveViewport = next
                onViewportChanged(next)
            }
            .onEnded { value in
                let isClick = hypot(value.translation.width, value.translation.height) < 4
                if isClick, dragBeganOutsideWindow {
                    onBackgroundTap?()
                }
                if let liveViewport {
                    onViewportChanged(liveViewport)
                }
                dragKind = nil
                dragOrigin = nil
                liveViewport = nil
                dragBeganOutsideWindow = false
            }
    }

    private func beginDrag(at locationX: CGFloat, containerWidth: CGFloat) {
        let origin = viewport
        let startX = xPosition(for: origin.start, containerWidth: containerWidth)
        let endX = xPosition(for: origin.end, containerWidth: containerWidth)
        let hit = Self.edgeHitWidth

        if abs(locationX - startX) <= hit {
            dragBeganOutsideWindow = false
            dragOrigin = origin
            liveViewport = origin
            dragKind = .resize(.start)
            return
        }
        if abs(locationX - endX) <= hit {
            dragBeganOutsideWindow = false
            dragOrigin = origin
            liveViewport = origin
            dragKind = .resize(.end)
            return
        }
        if locationX >= startX - hit, locationX <= endX + hit {
            dragBeganOutsideWindow = false
            dragOrigin = origin
            liveViewport = origin
            dragKind = .pan(
                grabOffset: time(at: locationX, containerWidth: containerWidth) - origin.start
            )
            return
        }

        dragBeganOutsideWindow = true
        let centered = TimelineViewport(
            start: time(at: locationX, containerWidth: containerWidth) - origin.duration / 2,
            duration: origin.duration,
            sourceDuration: sourceDuration
        )
        dragOrigin = centered
        liveViewport = centered
        dragKind = .pan(grabOffset: centered.duration / 2)
        onViewportChanged(centered)
    }

    private func time(at locationX: CGFloat, containerWidth: CGFloat) -> TimeInterval {
        let fraction = min(max(locationX / containerWidth, 0), 1)
        return sourceDuration * Double(fraction)
    }

    private func xPosition(for time: TimeInterval, containerWidth: CGFloat) -> CGFloat {
        guard sourceDuration > 0 else {
            return 0
        }
        return containerWidth * CGFloat(time / sourceDuration)
    }

    private func format(_ time: TimeInterval) -> String {
        let seconds = max(Int(time.rounded()), 0)
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}

struct WaveformTimelineControls: View {
    let canFitRegion: Bool
    let isEnabled: Bool
    let onZoom: (Double) -> Void
    let onPan: (Double) -> Void
    let onShowFull: () -> Void
    let onFitRegion: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Button(
                action: { onPan(-0.25) },
                label: { Image(systemName: "chevron.left") }
            )
            Button(
                action: { onZoom(0.5) },
                label: { Image(systemName: "minus.magnifyingglass") }
            )
            Button(
                action: { onZoom(2) },
                label: { Image(systemName: "plus.magnifyingglass") }
            )
            Button(
                action: { onPan(0.25) },
                label: { Image(systemName: "chevron.right") }
            )
            Divider().frame(height: 16)
            Button("Full", action: onShowFull)
            Button("Selection", action: onFitRegion)
                .disabled(!canFitRegion)
        }
        .buttonStyle(.borderless)
        .disabled(!isEnabled)
        .accessibilityElement(children: .contain)
    }
}
