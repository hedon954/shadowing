import SwiftUI

/// v8 card: the original waveform with the selected (or live) take on the same timeline under it,
/// a faint band on the current sentence, one playhead through both, then the time axis.
struct OriginalWaveformSection: View {
    @ObservedObject var viewModel: PracticeViewModel
    var isCaptionVisible = false
    @State private var magnifyOrigin: TimelineViewport?

    static let labelWidth: CGFloat = 64
    static let labelGap: CGFloat = 14
    static var waveformLeading: CGFloat {
        labelWidth + labelGap
    }

    static let originalHeight: CGFloat = 64
    static let takeHeight: CGFloat = 52
    static let laneGap: CGFloat = 12

    private var isRecording: Bool {
        viewModel.recordingPresentation.locksPracticeControls
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            lanes
            WaveformRuler(viewport: viewModel.timelineViewport)
                .padding(.leading, Self.waveformLeading)
                .padding(.top, 8)
            if isCaptionVisible {
                SubtitleCaptionLine(viewModel: viewModel, subtitles: viewModel.subtitles)
                    .padding(.leading, Self.waveformLeading)
                    .padding(.top, 14)
            }
            if viewModel.isTimelineZoomed {
                zoomControls
                    .padding(.leading, Self.waveformLeading)
                    .padding(.top, 10)
            }
            if let warning = viewModel.waveform.warning {
                Label(warning, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.top, 8)
                    .accessibilityLabel("Waveform warning: \(warning)")
            }
        }
        .padding(EdgeInsets(top: 18, leading: 18, bottom: 12, trailing: 18))
        .background(PracticeCardBackground())
        .simultaneousGesture(magnificationGesture)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Aligned original and recording waveforms")
    }

    private var lanes: some View {
        VStack(alignment: .leading, spacing: Self.laneGap) {
            WaveformLaneRow(title: Text("Original"), detail: Text(verbatim: originalDuration), tint: .accentColor) {
                originalTrack
                    .frame(height: Self.originalHeight + WaveformBarStyle.original.verticalInset * 2)
                    .padding(.vertical, -WaveformBarStyle.original.verticalInset)
                    .background { pauseTicks }
            }
            if isRecording {
                LiveTakeLane(viewModel: viewModel)
            } else if let take = viewModel.compareTake {
                AlignedTakeLane(viewModel: viewModel, take: take)
            }
        }
        .background(alignment: .topLeading) {
            SentenceBandOverlay(
                viewport: viewModel.timelineViewport,
                sentence: viewModel.currentSentence,
                playhead: nil,
                leading: Self.waveformLeading
            )
        }
        .overlay(alignment: .topLeading) {
            SentenceBandOverlay(
                viewport: viewModel.timelineViewport,
                sentence: nil,
                playhead: viewModel.timelinePlayhead,
                playheadColor: isRecording ? .red : .accentColor,
                leading: Self.waveformLeading
            )
            .allowsHitTesting(false)
        }
    }

    private var originalDuration: String {
        ClockText.format(viewModel.project.duration)
    }

    /// Pause cuts, drawn only while pauses decide the sentence (no subtitles, no loop range).
    @ViewBuilder
    private var pauseTicks: some View {
        if viewModel.region == nil, viewModel.timedCues.isEmpty, !viewModel.sentenceChunks.isEmpty {
            PauseTickMarks(viewport: viewModel.timelineViewport, chunks: viewModel.sentenceChunks)
        }
    }

    private var originalTrack: some View {
        WaveformSelectableTrack(
            waveform: viewModel.waveform,
            viewport: viewModel.timelineViewport,
            sourceDuration: viewModel.project.duration,
            region: viewModel.region,
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
            playheadStyle: WaveformPlayheadStyle(color: .clear, width: 0),
            barStyle: .original,
            fillsSelection: false
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

/// Round times under the waveform at their true positions, plus both ends:
/// "0:00  0:30  1:00  1:30  2:10".
struct WaveformRuler: View {
    let viewport: TimelineViewport

    var body: some View {
        GeometryReader { geometry in
            let ticks = Self.ticks(for: viewport)
            ZStack(alignment: .topLeading) {
                ForEach(Array(ticks.enumerated()), id: \.offset) { index, time in
                    label(time, index: index, count: ticks.count, width: geometry.size.width)
                }
            }
        }
        .frame(height: 13)
        .font(.system(size: 10.5).monospacedDigit())
        .foregroundStyle(.secondary)
        .accessibilityHidden(true)
    }

    private func label(_ time: TimeInterval, index: Int, count: Int, width: CGFloat) -> some View {
        let fraction = CGFloat((time - viewport.start) / max(viewport.duration, 0.001))
        let anchor: UnitPoint = index == 0 ? .topLeading : (index == count - 1 ? .topTrailing : .top)
        return Text(verbatim: ClockText.format(time))
            .fixedSize()
            .alignmentGuide(.leading) { dimension in
                dimension.width * anchor.x - fraction * width
            }
    }

    static let steps: [TimeInterval] = [1, 2, 5, 10, 15, 30, 60, 120, 300, 600, 900, 1800, 3600]

    /// Start, round multiples of the smallest step giving at most five intervals, and the end.
    /// Multiples too close to either end are dropped so labels never collide.
    static func ticks(for viewport: TimelineViewport) -> [TimeInterval] {
        let start = viewport.start
        let end = viewport.start + viewport.duration
        guard viewport.duration > 0 else {
            return [start]
        }
        let step = steps.first { viewport.duration / $0 <= 5 } ?? viewport.duration / 4
        let gap = viewport.duration * 0.12
        var ticks = [start]
        var time = (start / step).rounded(.down) * step + step
        while time < end - 0.0001 {
            if time - start >= gap, end - time >= gap {
                ticks.append(time)
            }
            time += step
        }
        ticks.append(end)
        return ticks
    }
}
