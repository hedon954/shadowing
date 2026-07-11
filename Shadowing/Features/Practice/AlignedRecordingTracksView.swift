import SwiftUI

struct RecordingWorkspaceView: View {
    @ObservedObject var viewModel: PracticeViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if viewModel.isComparing {
                CompareWorkspaceView(viewModel: viewModel)
            } else {
                recordingContent
            }
        }
    }

    private var recordingContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            AlignedRecordingTracksView(
                originalPeaks: viewModel.originalRecordingRegionPeaks,
                recordingPeaks: viewModel.liveRecordingPeaks,
                recordingProgress: viewModel.recordingProgressFraction
            )

            if let notice = viewModel.recordingNotice {
                Label(notice, systemImage: "headphones")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 12) {
                recordingIndicator
                Spacer()
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
            EmptyView()
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
        case .comparisonReady:
            EmptyView()
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

struct AlignedRecordingTracksView: View {
    let originalPeaks: [Float]
    let recordingPeaks: [Float]
    let recordingProgress: Double
    var originalEmphasis: Bool = true
    var takeEmphasis: Bool = true
    var playheadFraction: Double?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            track(
                TrackPresentation(
                    title: "Original",
                    peaks: originalPeaks,
                    color: .accentColor,
                    fillFraction: 1,
                    emphasized: originalEmphasis
                )
            )
            track(
                TrackPresentation(
                    title: "My Take",
                    peaks: recordingPeaks,
                    color: .orange,
                    fillFraction: recordingProgress,
                    emphasized: takeEmphasis
                )
            )
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Aligned original and recording waveforms")
    }

    private func track(_ presentation: TrackPresentation) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(presentation.title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(presentation.emphasized ? .secondary : .tertiary)
            PeakTrack(
                peaks: presentation.peaks,
                color: presentation.color.opacity(presentation.emphasized ? 1 : 0.35),
                fillFraction: presentation.fillFraction,
                playheadFraction: playheadFraction
            )
            .frame(height: 82)
            .opacity(presentation.emphasized ? 1 : 0.55)
        }
    }
}

private struct TrackPresentation {
    let title: String
    let peaks: [Float]
    let color: Color
    let fillFraction: Double
    let emphasized: Bool
}

private struct PeakTrack: View {
    let peaks: [Float]
    let color: Color
    let fillFraction: Double
    var playheadFraction: Double?

    var body: some View {
        Canvas { context, size in
            let barCount = min(max(Int(size.width / 3), 1), max(peaks.count, 1))
            let visibleWidth = size.width * min(max(fillFraction, 0), 1)
            let spacing = size.width / CGFloat(barCount)
            let centerY = size.height / 2

            for index in 0 ..< barCount {
                let xPosition = (CGFloat(index) + 0.5) * spacing
                guard xPosition <= visibleWidth, !peaks.isEmpty else {
                    continue
                }
                let peakIndex = min(index * peaks.count / barCount, peaks.count - 1)
                let amplitude = CGFloat(min(max(peaks[peakIndex], 0), 1))
                let halfHeight = max(amplitude * size.height * 0.42, 1)
                var path = Path()
                path.move(to: CGPoint(x: xPosition, y: centerY - halfHeight))
                path.addLine(to: CGPoint(x: xPosition, y: centerY + halfHeight))
                context.stroke(
                    path,
                    with: .color(color),
                    style: StrokeStyle(
                        lineWidth: max(spacing * 0.55, 1),
                        lineCap: .round
                    )
                )
            }

            if let playheadFraction {
                let xPosition = size.width * min(max(playheadFraction, 0), 1)
                var cursor = Path()
                cursor.move(to: CGPoint(x: xPosition, y: 0))
                cursor.addLine(to: CGPoint(x: xPosition, y: size.height))
                context.stroke(
                    cursor,
                    with: .color(.primary.opacity(0.55)),
                    lineWidth: 1
                )
            }
        }
        .padding(.horizontal, 8)
        .background(
            Color(nsColor: .controlBackgroundColor),
            in: RoundedRectangle(cornerRadius: 10)
        )
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(color.opacity(0.18))
                .frame(width: 1)
        }
        .accessibilityHidden(true)
    }
}
