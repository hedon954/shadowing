import SwiftUI

struct WaveformView: View {
    private enum Handle {
        case start
        case end
    }

    private static let dragThreshold: CGFloat = 4

    let peaks: [Float]
    let playhead: TimeInterval
    let duration: TimeInterval
    let region: PracticeRegion?
    let isEnabled: Bool
    let onSeek: (TimeInterval) -> Void
    let onRegionChanged: (PracticeRegion) -> Void

    @State private var draftRegion: PracticeRegion?

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                RoundedRectangle(cornerRadius: 14)
                    .fill(Color(nsColor: .controlBackgroundColor))

                if peaks.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "waveform")
                            .font(.title)
                        Text("Waveform unavailable")
                            .font(.callout)
                    }
                    .foregroundStyle(.secondary)
                }

                Canvas { context, size in
                    drawSelection(context: context, size: size)
                    drawWaveform(context: context, size: size)
                    drawPlayhead(context: context, size: size)
                }
                .padding(.vertical, 12)
                .accessibilityHidden(true)

                Color.clear
                    .contentShape(Rectangle())
                    .gesture(selectionGesture(size: geometry.size))
                    .accessibilityElement()
                    .accessibilityLabel("Audio waveform")
                    .accessibilityValue(accessibilityValue)
                    .accessibilityHint(
                        "Click to seek, or drag to select a practice region."
                    )
                    .accessibilityAdjustableAction { direction in
                        adjustPlayhead(direction)
                    }

                if let displayedRegion {
                    regionHandle(.start, region: displayedRegion, size: geometry.size)
                    regionHandle(.end, region: displayedRegion, size: geometry.size)
                }
            }
            .coordinateSpace(name: "practiceWaveform")
        }
        .frame(minHeight: 170)
        .accessibilityElement(children: .contain)
    }

    private func drawWaveform(context: GraphicsContext, size: CGSize) {
        guard !peaks.isEmpty else {
            return
        }
        let barCount = min(max(Int(size.width / 3), 1), peaks.count)
        let centerY = size.height / 2
        let spacing = size.width / CGFloat(barCount)

        for index in 0 ..< barCount {
            let peakIndex = min(index * peaks.count / barCount, peaks.count - 1)
            let amplitude = CGFloat(min(max(peaks[peakIndex], 0), 1))
            let halfHeight = max(amplitude * size.height * 0.42, 1)
            var path = Path()
            let xPosition = (CGFloat(index) + 0.5) * spacing
            path.move(to: CGPoint(x: xPosition, y: centerY - halfHeight))
            path.addLine(to: CGPoint(x: xPosition, y: centerY + halfHeight))
            let color = isSelected(xPosition, width: size.width)
                ? Color.accentColor
                : Color.secondary.opacity(0.55)
            context.stroke(
                path,
                with: .color(color),
                style: StrokeStyle(lineWidth: max(spacing * 0.55, 1), lineCap: .round)
            )
        }
    }

    private func drawSelection(context: GraphicsContext, size: CGSize) {
        guard let region = displayedRegion, duration > 0 else {
            return
        }
        let start = xPosition(for: region.start, width: size.width)
        let end = xPosition(for: region.end, width: size.width)
        let rectangle = CGRect(x: start, y: 0, width: end - start, height: size.height)
        context.fill(
            Path(roundedRect: rectangle, cornerRadius: 5),
            with: .color(.accentColor.opacity(0.13))
        )
    }

    private func drawPlayhead(context: GraphicsContext, size: CGSize) {
        guard duration > 0 else {
            return
        }
        let xPosition = xPosition(for: playhead, width: size.width)
        var path = Path()
        path.move(to: CGPoint(x: xPosition, y: 0))
        path.addLine(to: CGPoint(x: xPosition, y: size.height))
        context.stroke(path, with: .color(.accentColor), lineWidth: 2)

        let marker = CGRect(x: xPosition - 4, y: -1, width: 8, height: 8)
        context.fill(Path(ellipseIn: marker), with: .color(.accentColor))
    }

    private func selectionGesture(size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named("practiceWaveform"))
            .onChanged { value in
                guard isEnabled,
                      dragDistance(value) >= Self.dragThreshold
                else {
                    draftRegion = nil
                    return
                }
                draftRegion = makeRegion(
                    anchor: time(at: value.startLocation.x, width: size.width),
                    current: time(at: value.location.x, width: size.width)
                )
            }
            .onEnded { value in
                defer {
                    draftRegion = nil
                }
                guard isEnabled else {
                    return
                }
                if dragDistance(value) < Self.dragThreshold {
                    onSeek(time(at: value.location.x, width: size.width))
                } else if let selectedRegion = makeRegion(
                    anchor: time(at: value.startLocation.x, width: size.width),
                    current: time(at: value.location.x, width: size.width)
                ) {
                    onRegionChanged(selectedRegion)
                }
            }
    }

    private func regionHandle(
        _ handle: Handle,
        region: PracticeRegion,
        size: CGSize
    ) -> some View {
        let time = handle == .start ? region.start : region.end
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
        .contentShape(Rectangle())
        .position(
            x: xPosition(for: time, width: size.width),
            y: size.height / 2
        )
        .highPriorityGesture(handleGesture(handle, region: region, width: size.width))
        .accessibilityElement()
        .accessibilityLabel(handle == .start ? "Selection start" : "Selection end")
        .accessibilityValue(format(time))
        .accessibilityHint("Drag to adjust, or use accessibility increment and decrement.")
        .accessibilityAdjustableAction { direction in
            adjustHandle(handle, region: region, direction: direction)
        }
    }

    private func handleGesture(
        _ handle: Handle,
        region: PracticeRegion,
        width: CGFloat
    ) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named("practiceWaveform"))
            .onChanged { value in
                guard isEnabled else {
                    return
                }
                draftRegion = adjusted(
                    handle,
                    region: region,
                    to: time(at: value.location.x, width: width)
                )
            }
            .onEnded { value in
                defer {
                    draftRegion = nil
                }
                guard isEnabled,
                      let adjustedRegion = adjusted(
                          handle,
                          region: region,
                          to: time(at: value.location.x, width: width)
                      )
                else {
                    return
                }
                onRegionChanged(adjustedRegion)
            }
    }

    private func adjustHandle(
        _ handle: Handle,
        region: PracticeRegion,
        direction: AccessibilityAdjustmentDirection
    ) {
        guard isEnabled else {
            return
        }
        let delta: TimeInterval
        switch direction {
        case .increment:
            delta = PracticeRegion.minimumDuration
        case .decrement:
            delta = -PracticeRegion.minimumDuration
        @unknown default:
            return
        }
        let current = handle == .start ? region.start : region.end
        if let adjusted = adjusted(handle, region: region, to: current + delta) {
            onRegionChanged(adjusted)
        }
    }

    private func adjustPlayhead(_ direction: AccessibilityAdjustmentDirection) {
        guard isEnabled else {
            return
        }
        switch direction {
        case .increment:
            onSeek(min(playhead + 5, duration))
        case .decrement:
            onSeek(max(playhead - 5, 0))
        @unknown default:
            return
        }
    }

    private func adjusted(
        _ handle: Handle,
        region: PracticeRegion,
        to time: TimeInterval
    ) -> PracticeRegion? {
        switch handle {
        case .start:
            try? region.adjustingStart(to: time, sourceDuration: duration)
        case .end:
            try? region.adjustingEnd(to: time, sourceDuration: duration)
        }
    }

    private func makeRegion(
        anchor: TimeInterval,
        current: TimeInterval
    ) -> PracticeRegion? {
        try? PracticeRegion.fromDrag(
            anchor: anchor,
            current: current,
            sourceDuration: duration
        )
    }

    private var displayedRegion: PracticeRegion? {
        draftRegion ?? region
    }

    private var accessibilityValue: String {
        let playheadValue = "\(format(playhead)) of \(format(duration))"
        guard let region else {
            return "\(playheadValue), no selection"
        }
        return "\(playheadValue), selected \(format(region.start)) to \(format(region.end))"
    }

    private func isSelected(_ xPosition: CGFloat, width: CGFloat) -> Bool {
        guard let region = displayedRegion else {
            return false
        }
        let start = self.xPosition(for: region.start, width: width)
        let end = self.xPosition(for: region.end, width: width)
        return start ... end ~= xPosition
    }

    private func dragDistance(_ value: DragGesture.Value) -> CGFloat {
        hypot(value.translation.width, value.translation.height)
    }

    private func time(at xPosition: CGFloat, width: CGFloat) -> TimeInterval {
        guard duration > 0, width > 0 else {
            return 0
        }
        let fraction = min(max(xPosition / width, 0), 1)
        return duration * fraction
    }

    private func xPosition(for time: TimeInterval, width: CGFloat) -> CGFloat {
        guard duration > 0 else {
            return 0
        }
        return width * min(max(time / duration, 0), 1)
    }

    private func format(_ time: TimeInterval) -> String {
        let seconds = max(Int(time.rounded()), 0)
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}
