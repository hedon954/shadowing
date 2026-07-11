@preconcurrency import AppKit
import SwiftUI

struct WaveformView: View {
    fileprivate enum Handle {
        case start
        case end
    }

    fileprivate enum DragKind {
        case pan
        case select
        case resize(Handle)
    }

    private static let dragThreshold: CGFloat = 4
    private static let handleHitRadius: CGFloat = 14

    let waveform: WaveformPresentation
    let playhead: TimeInterval
    let duration: TimeInterval
    let region: PracticeRegion?
    let viewport: TimelineViewport
    let isEnabled: Bool
    let onSeek: (TimeInterval) -> Void
    let onRegionChanged: (PracticeRegion) -> Void
    let onRegionCleared: () -> Void
    let onViewportChanged: (TimelineViewport) -> Void
    var onGestureActiveChanged: ((Bool) -> Void)?
    let onShowFull: () -> Void
    let onFitRegion: () -> Void

    @State private var draftRegion: PracticeRegion?
    @State private var dragKind: DragKind?
    @State private var dragBaseRegion: PracticeRegion?
    @State private var panOrigin: TimelineViewport?
    @State private var magnifyOrigin: TimelineViewport?
    @State private var isGestureActive = false

    var body: some View {
        VStack(spacing: 10) {
            WaveformTimelineOverview(
                waveform: waveform,
                sourceDuration: duration,
                viewport: viewport,
                region: region,
                playhead: playhead,
                isInteractive: isEnabled,
                onViewportChanged: onViewportChanged
            )

            GeometryReader { geometry in
                ZStack {
                    WaveformTimelineTrack(
                        waveform: waveform,
                        viewport: viewport,
                        color: .accentColor,
                        playhead: playhead,
                        selection: displayedRegion
                    )

                    Color.clear
                        .contentShape(Rectangle())
                        .gesture(interactionGesture(size: geometry.size))
                        .simultaneousGesture(magnificationGesture)
                        .accessibilityElement()
                        .accessibilityLabel("Audio waveform timeline")
                        .accessibilityValue(accessibilityValue)
                        .accessibilityHint(
                            "Click to seek, drag to select, Option-drag to pan, or pinch to zoom."
                        )
                        .accessibilityAdjustableAction(adjustPlayhead)

                    if let displayedRegion {
                        regionHandle(.start, region: displayedRegion, size: geometry.size)
                        regionHandle(.end, region: displayedRegion, size: geometry.size)
                        WaveformSelectionClearButton(
                            region: displayedRegion,
                            viewport: viewport,
                            containerSize: geometry.size,
                            isEnabled: isEnabled,
                            onClear: onRegionCleared
                        )
                    }
                }
                .coordinateSpace(name: "practiceWaveform")
            }
            .frame(minHeight: 240)

            HStack {
                Text(format(viewport.start))
                Spacer()
                WaveformTimelineControls(
                    canFitRegion: region != nil,
                    isEnabled: isEnabled,
                    onZoom: zoomFromCenter,
                    onPan: panByFraction,
                    onShowFull: onShowFull,
                    onFitRegion: onFitRegion
                )
                Spacer()
                Text(format(viewport.end))
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .contain)
    }

    private func interactionGesture(size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named("practiceWaveform"))
            .onChanged { value in
                handleInteractionChanged(value, size: size)
            }
            .onEnded { value in
                handleInteractionEnded(value, size: size)
            }
    }

    private var magnificationGesture: some Gesture {
        MagnifyGesture()
            .onChanged { value in
                guard isEnabled else {
                    return
                }
                let origin = magnifyOrigin ?? viewport
                magnifyOrigin = origin
                let anchor = origin.start + Double(value.startAnchor.x) * origin.duration
                onViewportChanged(
                    origin.zoomed(
                        by: value.magnification,
                        anchor: anchor,
                        sourceDuration: duration
                    )
                )
            }
            .onEnded { _ in
                magnifyOrigin = nil
            }
    }

    private func regionHandle(
        _ handle: Handle,
        region: PracticeRegion,
        size: CGSize
    ) -> some View {
        let value = handle == .start ? region.start : region.end
        return ZStack(alignment: .bottom) {
            Rectangle()
                .fill(Color.accentColor)
                .frame(width: 2)
            RoundedRectangle(cornerRadius: 2)
                .fill(Color(nsColor: .windowBackgroundColor))
                .overlay {
                    RoundedRectangle(cornerRadius: 2)
                        .stroke(Color.accentColor, lineWidth: 2)
                }
                .frame(width: 9, height: 20)
                .padding(.bottom, 7)
        }
        .frame(width: 28, height: size.height)
        .position(x: xPosition(for: value, width: size.width), y: size.height / 2)
        .allowsHitTesting(false)
        .accessibilityElement()
        .accessibilityLabel(handle == .start ? "Selection start" : "Selection end")
        .accessibilityValue(format(value))
    }
}

private extension WaveformView {
    func handleInteractionChanged(_ value: DragGesture.Value, size: CGSize) {
        guard isEnabled else {
            return
        }
        if NSEvent.modifierFlags.contains(.option) {
            updatePan(value, size: size)
            return
        }
        resolveDragKindIfNeeded(value, width: size.width)
        updateActiveDrag(value, width: size.width)
    }

    func handleInteractionEnded(_ value: DragGesture.Value, size: CGSize) {
        defer {
            draftRegion = nil
            dragKind = nil
            dragBaseRegion = nil
            panOrigin = nil
            markGestureActive(false)
        }
        guard isEnabled else {
            return
        }
        switch dragKind {
        case .pan:
            return
        case let .resize(handle):
            commitResize(handle, at: value.location.x, width: size.width)
        case .select:
            commitSelection(value, width: size.width)
        case .none:
            if dragDistance(value) < Self.dragThreshold {
                onSeek(time(at: value.location.x, width: size.width))
            }
        }
    }

    func updatePan(_ value: DragGesture.Value, size: CGSize) {
        beginDrag(.pan)
        let origin = panOrigin ?? viewport
        panOrigin = origin
        let offset = -Double(value.translation.width / max(size.width, 1)) * origin.duration
        onViewportChanged(origin.panned(by: offset, sourceDuration: duration))
        draftRegion = nil
    }

    func resolveDragKindIfNeeded(_ value: DragGesture.Value, width: CGFloat) {
        guard dragKind == nil else {
            return
        }
        if let currentRegion = region {
            if let handle = hitHandle(
                at: value.startLocation,
                region: currentRegion,
                width: width
            ) {
                dragBaseRegion = currentRegion
                beginDrag(.resize(handle))
                return
            }
        }
        if dragDistance(value) >= Self.dragThreshold {
            beginDrag(.select)
        }
    }

    func updateActiveDrag(_ value: DragGesture.Value, width: CGFloat) {
        switch dragKind {
        case let .resize(handle):
            guard let base = dragBaseRegion else {
                return
            }
            draftRegion = adjusted(
                handle,
                region: base,
                to: time(at: value.location.x, width: width)
            )
        case .select:
            draftRegion = makeRegion(
                anchor: time(at: value.startLocation.x, width: width),
                current: time(at: value.location.x, width: width)
            )
        case .pan, .none:
            break
        }
    }

    func commitResize(_ handle: Handle, at locationX: CGFloat, width: CGFloat) {
        guard let base = dragBaseRegion,
              let next = adjusted(
                  handle,
                  region: base,
                  to: time(at: locationX, width: width)
              ),
              next != base
        else {
            return
        }
        onRegionChanged(next)
    }

    func commitSelection(_ value: DragGesture.Value, width: CGFloat) {
        guard let selected = makeRegion(
            anchor: time(at: value.startLocation.x, width: width),
            current: time(at: value.location.x, width: width)
        ) else {
            return
        }
        onRegionChanged(selected)
    }

    func beginDrag(_ kind: DragKind) {
        if dragKind == nil {
            dragKind = kind
            markGestureActive(true)
        }
    }

    func hitHandle(
        at point: CGPoint,
        region: PracticeRegion,
        width: CGFloat
    ) -> Handle? {
        let startX = xPosition(for: region.start, width: width)
        let endX = xPosition(for: region.end, width: width)
        let startDistance = abs(point.x - startX)
        let endDistance = abs(point.x - endX)
        if startDistance <= Self.handleHitRadius, startDistance <= endDistance {
            return .start
        }
        if endDistance <= Self.handleHitRadius {
            return .end
        }
        return nil
    }

    func markGestureActive(_ active: Bool) {
        guard isGestureActive != active else {
            return
        }
        isGestureActive = active
        onGestureActiveChanged?(active)
    }

    func adjusted(
        _ handle: Handle,
        region: PracticeRegion,
        to value: TimeInterval
    ) -> PracticeRegion? {
        switch handle {
        case .start:
            try? region.adjustingStart(to: value, sourceDuration: duration)
        case .end:
            try? region.adjustingEnd(to: value, sourceDuration: duration)
        }
    }

    func makeRegion(
        anchor: TimeInterval,
        current: TimeInterval
    ) -> PracticeRegion? {
        try? PracticeRegion.fromDrag(
            anchor: anchor,
            current: current,
            sourceDuration: duration
        )
    }

    func zoomFromCenter(_ factor: Double) {
        onViewportChanged(
            viewport.zoomed(
                by: factor,
                anchor: viewport.start + viewport.duration / 2,
                sourceDuration: duration
            )
        )
    }

    func panByFraction(_ fraction: Double) {
        onViewportChanged(
            viewport.panned(
                by: viewport.duration * fraction,
                sourceDuration: duration
            )
        )
    }

    func adjustPlayhead(_ direction: AccessibilityAdjustmentDirection) {
        guard isEnabled else {
            return
        }
        let delta = max(viewport.duration / 20, 0.1)
        switch direction {
        case .increment:
            onSeek(min(playhead + delta, duration))
        case .decrement:
            onSeek(max(playhead - delta, 0))
        @unknown default:
            return
        }
    }

    var displayedRegion: PracticeRegion? {
        draftRegion ?? region
    }

    var accessibilityValue: String {
        "Visible \(format(viewport.start)) to \(format(viewport.end)), " +
            "playhead \(format(playhead))"
    }

    func dragDistance(_ value: DragGesture.Value) -> CGFloat {
        hypot(value.translation.width, value.translation.height)
    }

    func time(at xPosition: CGFloat, width: CGFloat) -> TimeInterval {
        guard width > 0 else {
            return viewport.start
        }
        let fraction = min(max(xPosition / width, 0), 1)
        return viewport.start + viewport.duration * Double(fraction)
    }

    func xPosition(for time: TimeInterval, width: CGFloat) -> CGFloat {
        guard viewport.duration > 0 else {
            return 0
        }
        return width * CGFloat((time - viewport.start) / viewport.duration)
    }

    func format(_ time: TimeInterval) -> String {
        let seconds = max(Int(time.rounded()), 0)
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}
