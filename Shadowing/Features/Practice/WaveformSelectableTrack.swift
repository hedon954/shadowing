@preconcurrency import AppKit
import SwiftUI

/// Waveform surface that supports seek, drag-to-select, and region handles.
struct WaveformSelectableTrack: View {
    private enum Handle {
        case start
        case end
    }

    private enum DragKind {
        case pan
        case select
        case resize(Handle)
    }

    private static let dragThreshold: CGFloat = 4
    private static let handleHitRadius: CGFloat = 14

    let waveform: WaveformPresentation?
    let viewport: TimelineViewport
    let sourceDuration: TimeInterval
    let region: PracticeRegion?
    let playhead: TimeInterval?
    let isEnabled: Bool
    let onSeek: (TimeInterval) -> Void
    let onRegionChanged: (PracticeRegion) -> Void
    let onRegionCleared: () -> Void
    var onViewportChanged: ((TimelineViewport) -> Void)?
    /// Called when a selection or handle drag begins (`true`) or ends (`false`).
    var onGestureActiveChanged: ((Bool) -> Void)?
    var color: Color = .accentColor
    var assetTimelineStart: TimeInterval = 0
    /// When set, drag selections are clamped inside this source-timeline span.
    var selectionBounds: PracticeRegion?
    var accessibilityTitle: String = "Original waveform"
    var accessibilityHintText: String = "Drag to select a loop region, or click to seek."
    var coordinateSpaceName: String = "selectableWaveformTrack"

    @State private var draftRegion: PracticeRegion?
    @State private var dragKind: DragKind?
    @State private var dragBaseRegion: PracticeRegion?
    @State private var panOrigin: TimelineViewport?
    @State private var isGestureActive = false

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                WaveformTimelineTrack(
                    waveform: waveform,
                    assetTimelineStart: assetTimelineStart,
                    viewport: viewport,
                    color: color,
                    playhead: playhead,
                    selection: displayedRegion,
                    emphasized: true
                )

                // Stable full-width layer: gestures must not live on moving handles.
                Color.clear
                    .contentShape(Rectangle())
                    .gesture(interactionGesture(size: geometry.size))
                    .accessibilityElement()
                    .accessibilityLabel(accessibilityTitle)
                    .accessibilityHint(accessibilityHintText)

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
            .coordinateSpace(name: coordinateSpaceName)
        }
    }

    private var displayedRegion: PracticeRegion? {
        draftRegion ?? region
    }

    private func interactionGesture(size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named(coordinateSpaceName))
            .onChanged { value in
                handleInteractionChanged(value, size: size)
            }
            .onEnded { value in
                handleInteractionEnded(value, size: size)
            }
    }

    private func handleInteractionChanged(_ value: DragGesture.Value, size: CGSize) {
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

    private func handleInteractionEnded(_ value: DragGesture.Value, size: CGSize) {
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

    private func updatePan(_ value: DragGesture.Value, size: CGSize) {
        beginDrag(.pan)
        let origin = panOrigin ?? viewport
        panOrigin = origin
        let offset = -Double(value.translation.width / max(size.width, 1)) * origin.duration
        onViewportChanged?(origin.panned(by: offset, sourceDuration: sourceDuration))
        draftRegion = nil
    }

    private func resolveDragKindIfNeeded(_ value: DragGesture.Value, width: CGFloat) {
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

    private func updateActiveDrag(_ value: DragGesture.Value, width: CGFloat) {
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

    private func commitResize(_ handle: Handle, at locationX: CGFloat, width: CGFloat) {
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

    private func commitSelection(_ value: DragGesture.Value, width: CGFloat) {
        guard let selected = makeRegion(
            anchor: time(at: value.startLocation.x, width: width),
            current: time(at: value.location.x, width: width)
        ) else {
            return
        }
        onRegionChanged(selected)
    }

    private func beginDrag(_ kind: DragKind) {
        if dragKind == nil {
            dragKind = kind
            markGestureActive(true)
        }
    }

    private func hitHandle(
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

    private func regionHandle(
        _ handle: Handle,
        region: PracticeRegion,
        size: CGSize
    ) -> some View {
        let value = handle == .start ? region.start : region.end
        return ZStack(alignment: .bottom) {
            Rectangle()
                .fill(color)
                .frame(width: 2)
            RoundedRectangle(cornerRadius: 2)
                .fill(Color(nsColor: .windowBackgroundColor))
                .overlay {
                    RoundedRectangle(cornerRadius: 2)
                        .stroke(color, lineWidth: 2)
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

    private func markGestureActive(_ active: Bool) {
        guard isGestureActive != active else {
            return
        }
        isGestureActive = active
        onGestureActiveChanged?(active)
    }

    private func adjusted(
        _ handle: Handle,
        region: PracticeRegion,
        to value: TimeInterval
    ) -> PracticeRegion? {
        let draft: PracticeRegion? = switch handle {
        case .start:
            try? region.adjustingStart(to: value, sourceDuration: sourceDuration)
        case .end:
            try? region.adjustingEnd(to: value, sourceDuration: sourceDuration)
        }
        guard let draft else {
            return nil
        }
        guard let selectionBounds else {
            return draft
        }
        return TakePlaybackTiming.clampedSelection(
            draft,
            takeRegion: selectionBounds,
            sourceDuration: sourceDuration
        )
    }

    private func makeRegion(
        anchor: TimeInterval,
        current: TimeInterval
    ) -> PracticeRegion? {
        if let selectionBounds {
            return TakePlaybackTiming.selectionFromDrag(
                anchor: anchor,
                current: current,
                takeRegion: selectionBounds,
                sourceDuration: sourceDuration
            )
        }
        return try? PracticeRegion.fromDrag(
            anchor: anchor,
            current: current,
            sourceDuration: sourceDuration
        )
    }

    private func dragDistance(_ value: DragGesture.Value) -> CGFloat {
        hypot(value.translation.width, value.translation.height)
    }

    private func time(at xPosition: CGFloat, width: CGFloat) -> TimeInterval {
        guard width > 0 else {
            return viewport.start
        }
        let fraction = min(max(xPosition / width, 0), 1)
        return viewport.start + viewport.duration * Double(fraction)
    }

    private func xPosition(for time: TimeInterval, width: CGFloat) -> CGFloat {
        guard viewport.duration > 0 else {
            return 0
        }
        return width * CGFloat((time - viewport.start) / viewport.duration)
    }

    private func format(_ time: TimeInterval) -> String {
        let seconds = max(Int(time.rounded()), 0)
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}

struct WaveformSelectionClearButton: View {
    let region: PracticeRegion
    let viewport: TimelineViewport
    let containerSize: CGSize
    let isEnabled: Bool
    let onClear: () -> Void

    var body: some View {
        Button(
            action: onClear,
            label: {
                Image(systemName: "xmark")
                    .font(.caption2.weight(.bold))
                    .frame(width: 20, height: 20)
                    .background(.regularMaterial, in: Circle())
                    .overlay {
                        Circle()
                            .stroke(Color.accentColor.opacity(0.7), lineWidth: 1)
                    }
            }
        )
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .help("Cancel selection")
        .accessibilityLabel("Cancel practice selection")
        .position(x: horizontalPosition, y: 14)
    }

    private var horizontalPosition: CGFloat {
        guard viewport.duration > 0 else {
            return 12
        }
        // Keep clear control away from the end handle hit target.
        let endPosition = containerSize.width *
            CGFloat((region.end - viewport.start) / viewport.duration)
        let startPosition = containerSize.width *
            CGFloat((region.start - viewport.start) / viewport.duration)
        let preferred = endPosition - 36
        let midpoint = (startPosition + endPosition) / 2
        let clearX = preferred > startPosition + 24 ? preferred : midpoint
        return min(
            max(clearX, 12),
            max(containerSize.width - 12, 12)
        )
    }
}
