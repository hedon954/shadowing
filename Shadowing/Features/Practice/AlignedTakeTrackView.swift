import SwiftUI

struct AlignedTakeTrackView: View {
    let take: Take
    let waveform: WaveformPresentation?
    let liveTakePoints: [TimedWaveformEnvelopePoint]
    let liveRegion: PracticeRegion?
    let loopSelection: PracticeRegion?
    let viewport: TimelineViewport
    let sourceDuration: TimeInterval
    let playhead: TimeInterval?
    let isSelected: Bool
    let isLive: Bool
    let isPlaying: Bool
    let isInteractive: Bool
    var canReorder = false
    let onSelectTake: () -> Void
    let onTogglePlayback: () -> Void
    let onSeek: (TimeInterval) -> Void
    let onLoopRegionChanged: (PracticeRegion) -> Void
    let onLoopRegionCleared: () -> Void
    var onViewportChanged: ((TimelineViewport) -> Void)?
    var onGestureActiveChanged: ((Bool) -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                if canReorder {
                    Image(systemName: "line.3.horizontal")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                        .help("Drag to reorder takes")
                        .accessibilityLabel("Reorder Take \(take.sequence)")
                }
                Text("Take \(take.sequence)")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(isSelected || isLive ? .secondary : .tertiary)
                Spacer()
                playButton
            }
            .contentShape(Rectangle())
            .onTapGesture {
                guard isInteractive else {
                    return
                }
                onSelectTake()
            }

            Group {
                if isLive {
                    liveWaveform
                } else {
                    WaveformSelectableTrack(
                        waveform: waveform,
                        viewport: viewport,
                        sourceDuration: sourceDuration,
                        region: loopSelection,
                        playhead: playhead,
                        isEnabled: isInteractive,
                        onSeek: { time in
                            onSelectTake()
                            onSeek(time)
                        },
                        onRegionChanged: { region in
                            onSelectTake()
                            onLoopRegionChanged(region)
                        },
                        onRegionCleared: onLoopRegionCleared,
                        onViewportChanged: onViewportChanged,
                        onGestureActiveChanged: onGestureActiveChanged,
                        color: .orange,
                        assetTimelineStart: take.region.start,
                        selectionBounds: take.region,
                        accessibilityTitle: "Take \(take.sequence) waveform",
                        accessibilityHintText: """
                        Drag to select a Take loop region, or click to seek.
                        """,
                        coordinateSpaceName: "takeWaveform-\(take.id.uuidString)"
                    )
                }
            }
            .frame(height: 100)
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 8)
        .background {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(trackFill)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(trackStroke, lineWidth: isSelected || isLive ? 1.5 : 1)
        }
    }

    private var trackFill: Color {
        if isSelected || isLive {
            Color.accentColor.opacity(0.06)
        } else {
            Color.primary.opacity(0.035)
        }
    }

    private var trackStroke: Color {
        if isSelected || isLive {
            Color.accentColor.opacity(0.55)
        } else {
            Color.primary.opacity(0.12)
        }
    }

    private var playButton: some View {
        Button(action: onTogglePlayback) {
            Image(
                systemName: isPlaying ? "pause.fill" : "play.fill"
            )
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .disabled(!isInteractive)
        .accessibilityLabel(
            isPlaying
                ? "Pause Take \(take.sequence)"
                : "Play Take \(take.sequence)"
        )
    }

    private var liveWaveform: some View {
        ZStack {
            // Keep the committed take visible underneath so overwrite recording
            // does not flash an empty track before live peaks arrive.
            WaveformTimelineTrack(
                waveform: waveform,
                assetTimelineStart: take.region.start,
                viewport: viewport,
                color: .orange.opacity(0.35),
                playhead: nil,
                selection: take.region,
                emphasized: false,
                showsChrome: false
            )
            WaveformTimelineTrack(
                waveform: nil,
                timedPoints: liveTakePoints,
                assetTimelineStart: liveRegion?.start ?? take.region.start,
                viewport: viewport,
                color: .orange,
                playhead: playhead,
                selection: liveRegion ?? take.region,
                emphasized: true,
                showsChrome: false
            )
        }
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}
