import SwiftUI

/// "Takes" header and the newest-first list of takes. Selecting a take plays it.
struct TakesListSection: View {
    @ObservedObject var viewModel: PracticeViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            header
                .padding(.horizontal, 20)
            if let notice = viewModel.comparisonRegionNotice ?? viewModel.recordingNotice {
                Label(notice, systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 20)
            }
            List(selection: selection) {
                if viewModel.showsLiveTakeRow {
                    LiveTakeRow(viewModel: viewModel)
                        .selectionDisabled()
                        .listRowBackground(Color.red.opacity(0.14))
                }
                ForEach(viewModel.takes) { take in
                    TakeRow(
                        take: take,
                        waveform: viewModel.takeWaveforms[take.id],
                        isSelected: viewModel.activeTake?.id == take.id,
                        longestDuration: viewModel.longestTakeDuration
                    )
                    .tag(take.id)
                    .contextMenu {
                        contextMenu(for: take)
                    }
                }
                .onMove(perform: move)
                .moveDisabled(!canReorder)
            }
            .listStyle(.inset)
            .scrollContentBackground(.hidden)
            .disabled(viewModel.controlsLocked)
            .accessibilityLabel("Takes")
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("Takes")
                .font(.system(size: 13, weight: .bold))
            Text(verbatim: "\(viewModel.takes.count + (liveRowAddsTake ? 1 : 0))")
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
            Spacer()
        }
        .accessibilityElement(children: .combine)
    }

    /// Recording over a selected take replaces it, so only a new take raises the count.
    private var liveRowAddsTake: Bool {
        guard viewModel.showsLiveTakeRow else {
            return false
        }
        return !viewModel.takes.contains { $0.sequence == viewModel.recordingTakeNumber }
    }

    private var canReorder: Bool {
        !viewModel.controlsLocked && viewModel.takes.count > 1
    }

    private var selection: Binding<UUID?> {
        Binding(
            get: { viewModel.activeTake?.id },
            set: { id in
                guard let id else {
                    viewModel.clearTakeSelection()
                    return
                }
                guard id != viewModel.activeTake?.id,
                      let take = viewModel.takes.first(where: { $0.id == id })
                else {
                    return
                }
                viewModel.toggleTakePlayback(take)
            }
        )
    }

    @ViewBuilder
    private func contextMenu(for take: Take) -> some View {
        let isPlaying = viewModel.playingTakeID == take.id && viewModel.isPlaying
        Button(isPlaying ? "Pause Take \(take.sequence)" : "Play Take \(take.sequence)") {
            viewModel.toggleTakePlayback(take)
        }
        Divider()
        Button("Delete", role: .destructive) {
            viewModel.requestDeleteTake(take)
        }
        .accessibilityLabel("Delete Take \(take.sequence)")
    }

    private func move(from source: IndexSet, to destination: Int) {
        guard let from = source.first, source.count == 1 else {
            return
        }
        let targetIndex = destination > from ? destination - 1 : destination
        guard targetIndex != from, viewModel.takes.indices.contains(targetIndex) else {
            return
        }
        viewModel.reorderTakes(
            draggedID: viewModel.takes[from].id,
            onto: viewModel.takes[targetIndex].id
        )
    }
}

private struct TakeRow: View {
    let take: Take
    let waveform: WaveformPresentation?
    let isSelected: Bool
    let longestDuration: TimeInterval

    var body: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Take \(take.sequence)")
                    .fontWeight(.semibold)
                Text(take.createdAt, format: .practiceDayTime)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(width: 96, alignment: .leading)
            MiniWaveform(
                waveform: waveform,
                duration: take.duration,
                longestDuration: longestDuration,
                color: isSelected ? .accentColor : Color(nsColor: .tertiaryLabelColor)
            )
            Text(verbatim: ClockText.duration(take.duration))
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(minWidth: 44, alignment: .trailing)
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Take \(take.sequence)")
        .accessibilityValue(
            Text("\(take.createdAt, format: .practiceDayTime), \(ClockText.duration(take.duration))")
        )
        .accessibilityHint("Select to play this take.")
    }
}

private struct LiveTakeRow: View {
    @ObservedObject var viewModel: PracticeViewModel

    var body: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    Circle()
                        .fill(.red)
                        .frame(width: 6, height: 6)
                    Text("Take \(viewModel.recordingTakeNumber)")
                        .fontWeight(.semibold)
                }
                .foregroundStyle(.red)
                status
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(width: 96, alignment: .leading)
            MiniWaveform(
                timedPoints: viewModel.liveRecordingEnvelope,
                duration: viewModel.recordingElapsed,
                longestDuration: viewModel.longestTakeDuration,
                color: .red
            )
            Text(verbatim: ClockText.duration(viewModel.recordingElapsed))
                .font(.callout.monospacedDigit())
                .foregroundStyle(.red)
                .frame(minWidth: 44, alignment: .trailing)
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "Recording, \(ClockText.duration(viewModel.recordingElapsed)) elapsed"
        )
    }

    @ViewBuilder
    private var status: some View {
        switch viewModel.recordingPresentation {
        case let .countingDown(remainingSeconds):
            Text("Recording starts in \(remainingSeconds)")
        case .finalizing:
            Text("Saving recording…")
        case .idle, .checkingPermission, .recording:
            Text("Recording")
        }
    }
}

/// A take's waveform drawn to the same time scale as the other rows.
private struct MiniWaveform: View {
    var waveform: WaveformPresentation?
    var timedPoints: [TimedWaveformEnvelopePoint] = []
    let duration: TimeInterval
    let longestDuration: TimeInterval
    let color: Color

    var body: some View {
        GeometryReader { geometry in
            let fraction = min(max(duration / max(longestDuration, 0.001), 0), 1)
            WaveformTimelineTrack(
                waveform: waveform,
                timedPoints: timedPoints,
                viewport: viewport,
                color: color,
                showsChrome: false
            )
            .frame(width: geometry.size.width * fraction)
        }
        .frame(height: 22)
        .frame(maxWidth: .infinity)
        .accessibilityHidden(true)
    }

    /// The take's own time range: recorded audio starts at zero.
    private var viewport: TimelineViewport {
        let length = max(waveform?.duration ?? duration, 0.25)
        return TimelineViewport(start: 0, duration: length, sourceDuration: length)
    }
}
