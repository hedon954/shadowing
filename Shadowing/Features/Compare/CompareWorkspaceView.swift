import SwiftUI

struct CompareWorkspaceView: View {
    @ObservedObject var viewModel: PracticeViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            modePicker

            HStack(alignment: .top, spacing: 18) {
                AlignedRecordingTracksView(
                    originalPeaks: viewModel.comparisonOriginalPeaks,
                    recordingPeaks: viewModel.selectedTakePeaks,
                    recordingProgress: 1,
                    originalEmphasis: viewModel.comparisonMode == .original,
                    takeEmphasis: viewModel.comparisonMode == .selectedTake,
                    playheadFraction: viewModel.comparisonProgressFraction
                )
                .frame(maxWidth: .infinity)

                takeList
                    .frame(width: 220)
            }

            if let notice = viewModel.comparisonRegionNotice ?? viewModel.recordingNotice {
                Label(notice, systemImage: "info.circle")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            comparisonControls
        }
    }

    private var modePicker: some View {
        Picker(
            "Comparison mode",
            selection: Binding(
                get: { viewModel.comparisonMode },
                set: { mode in
                    viewModel.setComparisonMode(mode)
                }
            )
        ) {
            Text("Original").tag(ComparisonMode.original)
            Text("My Take").tag(ComparisonMode.selectedTake)
        }
        .pickerStyle(.segmented)
        .frame(maxWidth: 320)
        .accessibilityLabel("Comparison mode")
    }

    private var takeList: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Takes")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            if viewModel.takes.isEmpty {
                Text("No takes yet")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 6) {
                        ForEach(viewModel.takes) { take in
                            takeRow(take)
                        }
                    }
                }
                .frame(maxHeight: 220)
            }
        }
        .padding(12)
        .background(
            Color(nsColor: .controlBackgroundColor),
            in: RoundedRectangle(cornerRadius: 12)
        )
    }

    private func takeRow(_ take: Take) -> some View {
        let isSelected = viewModel.activeTake?.id == take.id
        return Button {
            viewModel.selectTake(take)
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Take \(take.sequence)")
                        .fontWeight(isSelected ? .semibold : .regular)
                    Text(durationLabel(take.duration))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 4)
                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.tint)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                isSelected
                    ? Color.accentColor.opacity(0.12)
                    : Color.clear,
                in: RoundedRectangle(cornerRadius: 8)
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Take \(take.sequence)")
        .accessibilityValue(isSelected ? "Selected" : "Not selected")
        .accessibilityHint(durationLabel(take.duration))
    }

    private var comparisonControls: some View {
        HStack(spacing: 12) {
            if let take = viewModel.activeTake {
                Label(
                    "Take \(take.sequence) ready",
                    systemImage: "checkmark.circle.fill"
                )
                .foregroundStyle(.green)
            }

            Spacer()

            Button {
                viewModel.toggleComparisonPlayback()
            } label: {
                Label(
                    viewModel.isPlaying ? "Pause" : "Play",
                    systemImage: viewModel.isPlaying ? "pause.fill" : "play.fill"
                )
            }
            .buttonStyle(.borderedProminent)
            .accessibilityLabel(viewModel.isPlaying ? "Pause comparison" : "Play comparison")

            Button("Re-record") {
                viewModel.rerecord()
            }
            .buttonStyle(.bordered)
            .accessibilityLabel("Re-record")
            .accessibilityHint("Keeps existing takes and starts a new recording.")

            Button("Delete", role: .destructive) {
                viewModel.requestDeleteTake()
            }
            .buttonStyle(.bordered)
            .disabled(viewModel.activeTake == nil)
            .accessibilityLabel("Delete current take")
        }
    }

    private func durationLabel(_ duration: TimeInterval) -> String {
        let seconds = max(Int(duration.rounded()), 0)
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}
