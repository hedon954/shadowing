import SwiftUI

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
        ClockText.format(time)
    }
}
