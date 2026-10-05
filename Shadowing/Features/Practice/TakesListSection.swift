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
            List {
                if viewModel.showsLiveTakeRow {
                    LiveTakeRow(viewModel: viewModel)
                        .modifier(TakeListRowChrome())
                }
                ForEach(viewModel.takes) { take in
                    TakeRow(
                        take: take,
                        isComparing: viewModel.compareTake?.id == take.id && !viewModel.showsLiveTakeRow,
                        isPlaying: viewModel.playingTakeID == take.id && viewModel.isPlaying,
                        onPlay: { viewModel.toggleTakePlayback(take) },
                        onSelect: { viewModel.selectTake(take) },
                        onCompare: { viewModel.compare(with: take) }
                    )
                    .modifier(TakeListRowChrome())
                    .contextMenu {
                        contextMenu(for: take)
                    }
                }
                .onMove(perform: move)
                .moveDisabled(!canReorder)
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .environment(\.defaultMinListRowHeight, 1)
            .disabled(viewModel.controlsLocked)
            .accessibilityLabel("Takes")
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text("Takes")
                .font(.system(size: 12, weight: .semibold))
            Text(verbatim: "\(viewModel.takes.count + (liveRowAddsTake ? 1 : 0))")
                .font(.system(size: 12).monospacedDigit())
            Spacer()
        }
        .foregroundStyle(.secondary)
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

    @ViewBuilder
    private func contextMenu(for take: Take) -> some View {
        let isPlaying = viewModel.playingTakeID == take.id && viewModel.isPlaying
        Button(isPlaying ? "Pause Take \(take.sequence)" : "Play Take \(take.sequence)") {
            viewModel.toggleTakePlayback(take)
        }
        Button("Compare") {
            viewModel.compare(with: take)
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

/// List rows draw their own rounded background; no separators or system selection.
private struct TakeListRowChrome: ViewModifier {
    func body(content: Content) -> some View {
        content
            .listRowInsets(EdgeInsets(top: 0, leading: 8, bottom: 0, trailing: 8))
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
    }
}

/// ▶  第 3 遍 今天 09:12 ……… 正在对比 / 对比   1:58
private struct TakeRow: View {
    let take: Take
    let isComparing: Bool
    let isPlaying: Bool
    let onPlay: () -> Void
    let onSelect: () -> Void
    let onCompare: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            TakePlayButton(isPlaying: isPlaying, sequence: take.sequence, action: onPlay)
            TakeNameLabel(
                name: Text("Take \(take.sequence)"),
                detail: Text(verbatim: TakeDateText.short(take.createdAt))
            )
            Spacer(minLength: 8)
            if isComparing {
                Text("Comparing")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.tint)
            } else {
                Button("Compare take action", action: onCompare)
                    .buttonStyle(.plain)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .help("Compare the selected sentence with this take (C)")
                    .accessibilityLabel("Compare with Take \(take.sequence)")
            }
            TakeDurationText(duration: take.duration)
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 12)
        .background {
            if isComparing {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(Color.primary.opacity(0.045))
            }
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Take \(take.sequence)")
        .accessibilityValue(
            Text("\(TakeDateText.short(take.createdAt)), \(ClockText.duration(take.duration))")
        )
        .accessibilityAddTraits(isComparing ? .isSelected : [])
    }
}

private struct TakePlayButton: View {
    let isPlaying: Bool
    let sequence: Int
    var isEnabled = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                .font(.system(size: 9, weight: .bold))
                .frame(width: 26, height: 26)
                .background(Color.primary.opacity(0.05), in: Circle())
                .overlay(Circle().strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.45)
        .accessibilityLabel(isPlaying ? "Pause Take \(sequence)" : "Play Take \(sequence)")
    }
}

private struct TakeNameLabel: View {
    let name: Text
    let detail: Text
    var tint: Color = .primary

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            name
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(tint)
            detail
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        .lineLimit(1)
        .fixedSize()
        .frame(minWidth: 120, alignment: .leading)
    }
}

private struct TakeDurationText: View {
    let duration: TimeInterval

    var body: some View {
        Text(verbatim: ClockText.duration(duration))
            .font(.system(size: 12).monospacedDigit())
            .foregroundStyle(.secondary)
            .frame(width: 40, alignment: .trailing)
    }
}

/// The take being recorded, red, at the top of the list.
private struct LiveTakeRow: View {
    @ObservedObject var viewModel: PracticeViewModel

    var body: some View {
        HStack(spacing: 14) {
            TakePlayButton(isPlaying: false, sequence: viewModel.recordingTakeNumber, isEnabled: false) {}
            TakeNameLabel(name: Text("Take \(viewModel.recordingTakeNumber)"), detail: status, tint: .red)
            Spacer(minLength: 8)
            Text("Recording badge")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.red)
            TakeDurationText(duration: viewModel.recordingElapsed)
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 12)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "Recording, \(ClockText.duration(viewModel.recordingElapsed)) elapsed"
        )
    }

    private var status: Text {
        switch viewModel.recordingPresentation {
        case let .countingDown(remainingSeconds):
            Text("Recording starts in \(remainingSeconds)")
        case .finalizing:
            Text("Saving recording…")
        case .idle, .checkingPermission, .recording:
            Text("Recording…")
        }
    }
}
