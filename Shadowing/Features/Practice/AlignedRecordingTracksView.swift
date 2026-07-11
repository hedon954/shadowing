import SwiftUI

struct RecordingWorkspaceView: View {
    @ObservedObject var viewModel: PracticeViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            MultiTrackPracticeView(viewModel: viewModel)

            if let notice = viewModel.comparisonRegionNotice ?? viewModel.recordingNotice {
                Label(notice, systemImage: "info.circle")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 12) {
                recordingIndicator
                Spacer()
                if viewModel.activeTake != nil, !viewModel.controlsLocked {
                    Button("Delete Take", role: .destructive) {
                        viewModel.requestDeleteTake()
                    }
                    .buttonStyle(.bordered)
                    .accessibilityLabel("Delete current take")
                }
                if viewModel.recordingPresentation.locksPracticeControls {
                    stopButton
                }
            }
        }
    }

    @ViewBuilder
    private var recordingIndicator: some View {
        switch viewModel.recordingPresentation {
        case .idle:
            if let take = viewModel.activeTake {
                Label(
                    "Take \(take.sequence) selected",
                    systemImage: "checkmark.circle.fill"
                )
                .foregroundStyle(.secondary)
            }
        case .checkingPermission:
            Label("Checking microphone…", systemImage: "mic")
        case let .countingDown(remainingSeconds):
            Text("Recording starts in \(remainingSeconds)")
                .font(.title2.monospacedDigit().weight(.semibold))
        case .recording:
            HStack(spacing: 8) {
                Circle()
                    .fill(.red)
                    .frame(width: 9, height: 9)
                Text("REC")
                    .foregroundStyle(.red)
                    .fontWeight(.bold)
                Text(format(viewModel.recordingElapsed))
                    .monospacedDigit()
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(
                "Recording, \(format(viewModel.recordingElapsed)) elapsed"
            )
        case .finalizing:
            Label("Saving recording…", systemImage: "waveform.badge.magnifyingglass")
        }
    }

    private var stopButton: some View {
        Button(
            viewModel.recordingPresentation == .finalizing
                ? "Finishing…"
                : "Stop Recording"
        ) {
            viewModel.stopRecording()
        }
        .buttonStyle(.borderedProminent)
        .tint(.red)
        .disabled(viewModel.recordingPresentation == .finalizing)
        .accessibilityLabel("Stop Recording")
    }

    private func format(_ time: TimeInterval) -> String {
        let seconds = max(Int(time.rounded()), 0)
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}

struct MultiTrackPracticeView: View {
    @ObservedObject var viewModel: PracticeViewModel

    var body: some View {
        AlignedRecordingTracksView(
            originalWaveform: viewModel.waveform,
            takes: viewModel.takes,
            takeWaveforms: viewModel.takeWaveforms,
            takeLoopSelections: viewModel.takeLoopSelections,
            liveTakeID: liveTakeID,
            liveTakePoints: viewModel.liveRecordingTimelineEnvelope,
            liveRegion: viewModel.recordingDisplayRegion,
            sourceDuration: viewModel.project.duration,
            selectionRegion: viewModel.region,
            viewport: viewModel.timelineViewport,
            playhead: viewModel.timelinePlayhead,
            selectedTakeID: viewModel.activeTake?.id,
            playingTakeID: viewModel.playingTakeID,
            isPlaying: viewModel.isPlaying,
            isInteractive: !viewModel.controlsLocked,
            onSeek: viewModel.seekTimeline,
            onClearTakeSelection: viewModel.clearTakeSelection,
            onRegionChanged: viewModel.selectRegion,
            onRegionCleared: viewModel.clearRegion,
            onViewportChanged: viewModel.setTimelineViewport,
            onGestureActiveChanged: viewModel.setTimelineGestureActive,
            onShowFull: viewModel.showFullTimeline,
            onFitRegion: viewModel.fitTimelineToRegion,
            onSelectTake: viewModel.selectTake,
            onToggleTakePlayback: viewModel.toggleTakePlayback,
            onTakeLoopRegionChanged: viewModel.selectTakeLoopRegion,
            onTakeLoopRegionCleared: viewModel.clearTakeLoopRegion,
            onReorderTakes: viewModel.reorderTakes
        )
    }

    private var liveTakeID: UUID? {
        switch viewModel.recordingPresentation {
        case .checkingPermission, .countingDown, .recording, .finalizing:
            viewModel.recordingContext?.id ?? viewModel.activeTake?.id
        case .idle:
            nil
        }
    }
}

struct AlignedRecordingTracksView: View {
    let originalWaveform: WaveformPresentation
    let takes: [Take]
    let takeWaveforms: [UUID: WaveformPresentation]
    let takeLoopSelections: [UUID: PracticeRegion]
    let liveTakeID: UUID?
    let liveTakePoints: [TimedWaveformEnvelopePoint]
    let liveRegion: PracticeRegion?
    let sourceDuration: TimeInterval
    let selectionRegion: PracticeRegion?
    let viewport: TimelineViewport
    let playhead: TimeInterval?
    let selectedTakeID: UUID?
    let playingTakeID: UUID?
    let isPlaying: Bool
    var isInteractive = true
    let onSeek: (TimeInterval) -> Void
    let onClearTakeSelection: () -> Void
    let onRegionChanged: (PracticeRegion) -> Void
    let onRegionCleared: () -> Void
    let onViewportChanged: (TimelineViewport) -> Void
    var onGestureActiveChanged: ((Bool) -> Void)?
    let onShowFull: () -> Void
    let onFitRegion: () -> Void
    let onSelectTake: (Take) -> Void
    let onToggleTakePlayback: (Take) -> Void
    let onTakeLoopRegionChanged: (Take, PracticeRegion) -> Void
    let onTakeLoopRegionCleared: (Take) -> Void
    var onReorderTakes: ((UUID, UUID) -> Void)?

    @State private var magnifyOrigin: TimelineViewport?

    private var takeThumbnails: [WaveformTimelineOverview.TakeThumbnail] {
        takes.compactMap { take in
            guard let waveform = takeWaveforms[take.id] else {
                return nil
            }
            return WaveformTimelineOverview.TakeThumbnail(
                id: take.id,
                waveform: waveform,
                timelineStart: take.region.start,
                isSelected: take.id == selectedTakeID
            )
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            WaveformTimelineOverview(
                waveform: originalWaveform,
                takeThumbnails: takeThumbnails,
                sourceDuration: sourceDuration,
                viewport: viewport,
                region: selectionRegion ?? liveRegion,
                playhead: playhead ?? viewport.start,
                isInteractive: isInteractive,
                onViewportChanged: onViewportChanged,
                onBackgroundTap: onClearTakeSelection
            )

            trackHeader(title: "Original", emphasized: selectedTakeID == nil) {
                EmptyView()
            }
            .contentShape(Rectangle())
            .onTapGesture {
                guard isInteractive else {
                    return
                }
                onClearTakeSelection()
            }
            WaveformSelectableTrack(
                waveform: originalWaveform,
                viewport: viewport,
                sourceDuration: sourceDuration,
                region: selectionRegion,
                playhead: playhead,
                isEnabled: isInteractive,
                onSeek: { time in
                    onClearTakeSelection()
                    onSeek(time)
                },
                onRegionChanged: { region in
                    onClearTakeSelection()
                    onRegionChanged(region)
                },
                onRegionCleared: onRegionCleared,
                onViewportChanged: onViewportChanged,
                onGestureActiveChanged: onGestureActiveChanged
            )
            .frame(height: 120)

            Divider()
                .opacity(0.45)
                .padding(.vertical, 2)

            if showsAppendLiveRow {
                appendLiveRecordingRow
            }

            ForEach(takes) { take in
                AlignedTakeTrackView(
                    take: take,
                    waveform: takeWaveforms[take.id],
                    liveTakePoints: liveTakePoints,
                    liveRegion: liveRegion,
                    loopSelection: takeLoopSelections[take.id],
                    viewport: viewport,
                    sourceDuration: sourceDuration,
                    playhead: playhead,
                    isSelected: selectedTakeID == take.id,
                    isLive: liveTakeID == take.id,
                    isPlaying: playingTakeID == take.id && isPlaying,
                    isInteractive: isInteractive,
                    canReorder: canReorderTakes,
                    onSelectTake: { onSelectTake(take) },
                    onTogglePlayback: { onToggleTakePlayback(take) },
                    onSeek: onSeek,
                    onLoopRegionChanged: { region in
                        onTakeLoopRegionChanged(take, region)
                    },
                    onLoopRegionCleared: {
                        onTakeLoopRegionCleared(take)
                    },
                    onViewportChanged: onViewportChanged,
                    onGestureActiveChanged: onGestureActiveChanged
                )
                .onDrag {
                    guard canReorderTakes else {
                        return NSItemProvider()
                    }
                    return NSItemProvider(object: take.id.uuidString as NSString)
                }
                .onDrop(
                    of: [.plainText],
                    delegate: TakeTrackReorderDropDelegate(
                        targetID: take.id,
                        isEnabled: canReorderTakes,
                        onMove: { draggedID, targetID in
                            onReorderTakes?(draggedID, targetID)
                        }
                    )
                )
            }

            HStack {
                Text(format(viewport.start))
                Spacer()
                WaveformTimelineControls(
                    canFitRegion: selectionRegion != nil || liveRegion != nil,
                    isEnabled: isInteractive,
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
        .simultaneousGesture(magnificationGesture)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Aligned original and recording waveforms")
    }

    private var canReorderTakes: Bool {
        isInteractive && takes.count > 1 && onReorderTakes != nil
    }

    private var showsAppendLiveRow: Bool {
        guard liveTakeID != nil, !liveTakePoints.isEmpty || liveRegion != nil else {
            return false
        }
        return !takes.contains(where: { $0.id == liveTakeID })
    }

    private var appendLiveRecordingRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            trackHeader(title: "Recording…", emphasized: true) {
                EmptyView()
            }
            WaveformTimelineTrack(
                waveform: nil,
                timedPoints: liveTakePoints,
                assetTimelineStart: liveRegion?.start ?? viewport.start,
                viewport: viewport,
                color: .orange,
                playhead: playhead,
                selection: liveRegion,
                emphasized: true
            )
            .frame(height: 100)
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .overlay {
                seekOverlay(clearsTakeSelection: false)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 8)
        .background {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.accentColor.opacity(0.06))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.accentColor.opacity(0.45), lineWidth: 1.5)
        }
    }

    private func trackHeader(
        title: String,
        emphasized: Bool,
        @ViewBuilder trailing: () -> some View
    ) -> some View {
        HStack {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(emphasized ? .secondary : .tertiary)
            Spacer()
            trailing()
        }
    }

    private func seekOverlay(clearsTakeSelection: Bool) -> some View {
        GeometryReader { geometry in
            Color.clear
                .contentShape(Rectangle())
                .gesture(
                    SpatialTapGesture()
                        .onEnded { value in
                            guard isInteractive, geometry.size.width > 0 else {
                                return
                            }
                            if clearsTakeSelection {
                                onClearTakeSelection()
                            }
                            let fraction = min(
                                max(value.location.x / geometry.size.width, 0),
                                1
                            )
                            onSeek(
                                viewport.start +
                                    viewport.duration * Double(fraction)
                            )
                        }
                )
        }
        .accessibilityHidden(true)
    }

    private var magnificationGesture: some Gesture {
        MagnifyGesture()
            .onChanged { value in
                guard isInteractive else {
                    return
                }
                let origin = magnifyOrigin ?? viewport
                magnifyOrigin = origin
                let anchor = origin.start + Double(value.startAnchor.x) * origin.duration
                onViewportChanged(
                    origin.zoomed(
                        by: Double(value.magnification),
                        anchor: anchor,
                        sourceDuration: sourceDuration
                    )
                )
            }
            .onEnded { _ in
                magnifyOrigin = nil
            }
    }

    private func zoomFromCenter(_ factor: Double) {
        onViewportChanged(
            viewport.zoomed(
                by: factor,
                anchor: viewport.start + viewport.duration / 2,
                sourceDuration: sourceDuration
            )
        )
    }

    private func panByFraction(_ fraction: Double) {
        onViewportChanged(
            viewport.panned(
                by: viewport.duration * fraction,
                sourceDuration: sourceDuration
            )
        )
    }

    private func format(_ time: TimeInterval) -> String {
        let seconds = max(Int(time.rounded()), 0)
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}

private struct TakeTrackReorderDropDelegate: DropDelegate {
    let targetID: UUID
    let isEnabled: Bool
    let onMove: (UUID, UUID) -> Void

    func validateDrop(info _: DropInfo) -> Bool {
        isEnabled
    }

    func dropUpdated(info _: DropInfo) -> DropProposal? {
        DropProposal(operation: isEnabled ? .move : .cancel)
    }

    func performDrop(info: DropInfo) -> Bool {
        guard isEnabled,
              let provider = info.itemProviders(for: [.plainText]).first
        else {
            return false
        }
        _ = provider.loadObject(ofClass: NSString.self) { object, _ in
            guard let string = object as? String,
                  let draggedID = UUID(uuidString: string)
            else {
                return
            }
            Task { @MainActor in
                onMove(draggedID, targetID)
            }
        }
        return true
    }
}
