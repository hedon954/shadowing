import SwiftUI

/// "Original" header, the source waveform with its ruler, and the selected take aligned under it.
struct OriginalWaveformSection: View {
    @ObservedObject var viewModel: PracticeViewModel
    @State private var magnifyOrigin: TimelineViewport?

    /// 72 pt of bars plus the playhead's 6 pt overhang above and below.
    static let trackHeight: CGFloat = 72 + WaveformBarStyle.original.verticalInset * 2

    private var isRecording: Bool {
        viewModel.recordingPresentation.locksPracticeControls
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            originalTrack
                .frame(height: Self.trackHeight)
                .padding(.vertical, -WaveformBarStyle.original.verticalInset)
            WaveformRuler(viewport: viewModel.timelineViewport)
            if let take = selectedTake {
                AlignedTakeLane(viewModel: viewModel, take: take)
            }
            if viewModel.isTimelineZoomed {
                zoomControls
            }
            if let warning = viewModel.waveform.warning {
                Label(warning, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Waveform warning: \(warning)")
            }
        }
        .simultaneousGesture(magnificationGesture)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Aligned original and recording waveforms")
    }

    /// The take lane appears only for a selected, saved take; live recording shows in the list.
    private var selectedTake: Take? {
        guard let take = viewModel.activeTake, !isRecording else {
            return nil
        }
        return viewModel.takes.first { $0.id == take.id }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text("Original")
                .font(.system(size: 13, weight: .bold))
            Spacer(minLength: 8)
            if let region = viewModel.region {
                Label(
                    "\(ClockText.duration(region.start)) – \(ClockText.duration(region.end))",
                    systemImage: "selection.pin.in.out"
                )
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .accessibilityLabel(regionAccessibilityLabel(region))
            }
            Text(
                verbatim: ClockText.paddedPosition(viewModel.playhead) + " / "
                    + ClockText.paddedPosition(viewModel.project.duration)
            )
            .font(.callout.monospacedDigit())
            .foregroundStyle(.secondary)
        }
    }

    private func regionAccessibilityLabel(_ region: PracticeRegion) -> Text {
        let start = ClockText.duration(region.start)
        let end = ClockText.duration(region.end)
        return Text("Selected region from \(start) to \(end)")
    }

    private var originalTrack: some View {
        WaveformSelectableTrack(
            waveform: viewModel.waveform,
            viewport: viewModel.timelineViewport,
            sourceDuration: viewModel.project.duration,
            region: viewModel.region ?? (isRecording ? viewModel.recordingDisplayRegion : nil),
            playhead: viewModel.timelinePlayhead,
            isEnabled: !viewModel.controlsLocked,
            onSeek: { time in
                viewModel.clearTakeSelection()
                viewModel.seekTimeline(time)
            },
            onRegionChanged: { region in
                viewModel.clearTakeSelection()
                viewModel.selectRegion(region)
            },
            onRegionCleared: viewModel.clearRegion,
            onViewportChanged: viewModel.setTimelineViewport,
            onGestureActiveChanged: viewModel.setTimelineGestureActive,
            color: Color(nsColor: .tertiaryLabelColor),
            showsChrome: false,
            playedColor: .accentColor,
            playheadStyle: WaveformPlayheadStyle(color: isRecording ? .red : .accentColor, width: 2),
            barStyle: .original
        )
        .help("Click to jump there. Drag across the waveform to select one sentence.")
        .contextMenu {
            zoomMenuItems
        }
    }

    @ViewBuilder
    private var zoomMenuItems: some View {
        Button("Zoom In") {
            zoom(by: 2)
        }
        Button("Zoom Out") {
            zoom(by: 0.5)
        }
        Divider()
        Button("Show Full Waveform", action: viewModel.showFullTimeline)
        Button("Zoom to Selection", action: viewModel.fitTimelineToRegion)
            .disabled(viewModel.region == nil && viewModel.recordingDisplayRegion == nil)
    }

    private var zoomControls: some View {
        VStack(spacing: 6) {
            WaveformTimelineOverview(
                waveform: viewModel.waveform,
                sourceDuration: viewModel.project.duration,
                viewport: viewModel.timelineViewport,
                region: viewModel.region ?? viewModel.recordingDisplayRegion,
                playhead: viewModel.timelinePlayhead,
                isInteractive: !viewModel.controlsLocked,
                onViewportChanged: viewModel.setTimelineViewport,
                onBackgroundTap: viewModel.clearTakeSelection
            )
            WaveformTimelineControls(
                canFitRegion: viewModel.region != nil || viewModel.recordingDisplayRegion != nil,
                isEnabled: !viewModel.controlsLocked,
                onZoom: zoom(by:),
                onPan: { fraction in
                    viewModel.setTimelineViewport(
                        viewModel.timelineViewport.panned(
                            by: viewModel.timelineViewport.duration * fraction,
                            sourceDuration: viewModel.project.duration
                        )
                    )
                },
                onShowFull: viewModel.showFullTimeline,
                onFitRegion: viewModel.fitTimelineToRegion
            )
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    private func zoom(by factor: Double) {
        let viewport = viewModel.timelineViewport
        viewModel.setTimelineViewport(
            viewport.zoomed(
                by: factor,
                anchor: viewport.start + viewport.duration / 2,
                sourceDuration: viewModel.project.duration
            )
        )
    }

    private var magnificationGesture: some Gesture {
        MagnifyGesture()
            .onChanged { value in
                guard !viewModel.controlsLocked else {
                    return
                }
                let origin = magnifyOrigin ?? viewModel.timelineViewport
                magnifyOrigin = origin
                let anchor = origin.start + Double(value.startAnchor.x) * origin.duration
                viewModel.setTimelineViewport(
                    origin.zoomed(
                        by: Double(value.magnification),
                        anchor: anchor,
                        sourceDuration: viewModel.project.duration
                    )
                )
            }
            .onEnded { _ in
                magnifyOrigin = nil
            }
    }
}

/// Five evenly spaced times under the waveform: "0:00  5:00  10:00  15:00  20:49".
struct WaveformRuler: View {
    let viewport: TimelineViewport

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(Self.ticks(for: viewport).enumerated()), id: \.offset) { index, time in
                Text(verbatim: ClockText.duration(time))
                    .frame(maxWidth: .infinity, alignment: alignment(for: index))
            }
        }
        .font(.system(size: 10.5).monospacedDigit())
        .foregroundStyle(.secondary)
        .accessibilityHidden(true)
    }

    static func ticks(for viewport: TimelineViewport, count: Int = 5) -> [TimeInterval] {
        guard count > 1 else {
            return [viewport.start]
        }
        return (0 ..< count).map { index in
            viewport.start + viewport.duration * Double(index) / Double(count - 1)
        }
    }

    private func alignment(for index: Int) -> Alignment {
        switch index {
        case 0:
            .leading
        case 4:
            .trailing
        default:
            .center
        }
    }
}

/// The selected take on the Original timeline, so it lines up with what was shadowed.
private struct AlignedTakeLane: View {
    @ObservedObject var viewModel: PracticeViewModel
    let take: Take

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Take \(take.sequence)")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            WaveformSelectableTrack(
                waveform: viewModel.takeWaveforms[take.id],
                viewport: viewModel.timelineViewport,
                sourceDuration: viewModel.project.duration,
                region: viewModel.takeLoopSelections[take.id],
                playhead: viewModel.timelinePlayhead,
                isEnabled: !viewModel.controlsLocked,
                onSeek: viewModel.seekTimeline,
                onRegionChanged: { region in
                    viewModel.selectTakeLoopRegion(take, region)
                },
                onRegionCleared: {
                    viewModel.clearTakeLoopRegion(take)
                },
                onViewportChanged: viewModel.setTimelineViewport,
                onGestureActiveChanged: viewModel.setTimelineGestureActive,
                color: .accentColor,
                assetTimelineStart: take.region.start,
                selectionBounds: take.region,
                accessibilityTitle: "Take \(take.sequence) waveform",
                accessibilityHintText: "Drag to select a Take loop region, or click to seek.",
                coordinateSpaceName: "takeWaveform-\(take.id.uuidString)",
                showsChrome: false
            )
            .frame(height: 40)
        }
    }
}
