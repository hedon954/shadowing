import SwiftUI

/// The white (dark: raised gray) rounded card behind the waveforms.
struct PracticeCardBackground: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 14, style: .continuous)
            .fill(Color(nsColor: .textBackgroundColor))
            .shadow(color: .black.opacity(0.04), radius: 1.5, y: 1)
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.09), lineWidth: 0.5)
            }
    }
}

/// "原音 / 2:10" or "第 3 遍 / 今天 09:12" in a 64 pt column, then the waveform.
struct WaveformLaneRow<Content: View>: View {
    let title: Text
    let detail: Text
    var tint: Color = .primary
    @ViewBuilder var content: Content

    var body: some View {
        HStack(spacing: OriginalWaveformSection.labelGap) {
            VStack(alignment: .leading, spacing: 1) {
                title
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(tint)
                detail
                    .font(.system(size: 10.5).monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .lineLimit(1)
            .fixedSize()
            .frame(width: OriginalWaveformSection.labelWidth, alignment: .leading)
            .accessibilityElement(children: .combine)
            content
                .frame(maxWidth: .infinity)
        }
    }
}

/// The selected take on the original timeline: drawn from its `region_start`, shifted by the
/// measured offset, primary before the playhead and gray after it.
struct AlignedTakeLane: View {
    @ObservedObject var viewModel: PracticeViewModel
    let take: Take

    var body: some View {
        WaveformLaneRow(
            title: Text("Take \(take.sequence)"),
            detail: Text(verbatim: TakeDateText.short(take.createdAt))
        ) {
            WaveformSelectableTrack(
                waveform: viewModel.takeWaveforms[take.id],
                viewport: viewModel.timelineViewport,
                sourceDuration: viewModel.project.duration,
                region: viewModel.takeLoopSelections[take.id],
                playhead: nil,
                clock: viewModel.playheadClock,
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
                color: Color(nsColor: .tertiaryLabelColor),
                assetTimelineStart: take.region.start - viewModel.alignmentOffset(for: take.id),
                selectionBounds: take.region,
                accessibilityTitle: "Take \(take.sequence) waveform",
                accessibilityHintText: "Drag to select a Take loop region, or click to seek.",
                coordinateSpaceName: "takeWaveform-\(take.id.uuidString)",
                showsChrome: false,
                playedColor: .primary,
                playheadStyle: WaveformPlayheadStyle(color: .clear, width: 0),
                barStyle: .original
            )
            .frame(height: OriginalWaveformSection.takeHeight + WaveformBarStyle.original.verticalInset * 2)
            .padding(.vertical, -WaveformBarStyle.original.verticalInset)
        }
    }
}

/// While recording, the new take draws itself in red under the original as the mic hears it.
struct LiveTakeLane: View {
    @ObservedObject var viewModel: PracticeViewModel

    var body: some View {
        WaveformLaneRow(
            title: Text("Take \(viewModel.recordingTakeNumber)"),
            detail: viewModel.isCapturingAudio
                ? Text("● Recording")
                : LiveTakeStatus.text(for: viewModel.recordingPresentation),
            tint: .red
        ) {
            WaveformTimelineTrack(
                waveform: nil,
                timedPoints: viewModel.liveRecordingTimelineEnvelope,
                viewport: viewModel.timelineViewport,
                color: .red,
                showsChrome: false,
                barStyle: .original
            )
            .frame(height: OriginalWaveformSection.takeHeight + WaveformBarStyle.original.verticalInset * 2)
            .padding(.vertical, -WaveformBarStyle.original.verticalInset)
            .accessibilityLabel("Live recording waveform")
        }
    }
}

/// The faint band on the current sentence (behind the bars) or the playhead (in front of them),
/// spanning both lanes. Positions follow the original timeline, offset by the label column.
struct SentenceBandOverlay: View {
    let viewport: TimelineViewport
    let sentence: SentenceChunk?
    let playhead: TimeInterval?
    /// The live playhead; when set only the cursor reads it, so a tick moves the cursor alone.
    var clock: PlayheadClock?
    var playheadColor: Color = .accentColor
    let leading: CGFloat

    static let bandOverhang: CGFloat = 8
    static let playheadOverhang: CGFloat = 10

    var body: some View {
        GeometryReader { geometry in
            let width = max(geometry.size.width - leading, 1)
            if let sentence, let frame = Self.bandFrame(sentence, viewport: viewport, width: width) {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.accentColor.opacity(0.09))
                    .frame(width: frame.width, height: geometry.size.height + Self.bandOverhang * 2)
                    .offset(x: leading + frame.minX, y: -Self.bandOverhang)
            }
        }
        .overlay(alignment: .topLeading) {
            if clock != nil || playhead != nil {
                Rectangle()
                    .fill(playheadColor)
                    .playheadMask(fixed: playhead, clock: clock) { position, width in
                        SentencePlayheadCursor(playhead: position, viewport: viewport, leading: leading, width: width)
                    }
                    .padding(.vertical, -Self.playheadOverhang)
            }
        }
        .accessibilityHidden(true)
    }

    static func x(for time: TimeInterval, viewport: TimelineViewport, width: CGFloat) -> CGFloat {
        CGFloat((time - viewport.start) / max(viewport.duration, 0.001)) * width
    }

    /// The band's horizontal span inside the waveform column, clipped to it; nil when off-screen.
    static func bandFrame(_ sentence: SentenceChunk, viewport: TimelineViewport, width: CGFloat) -> CGRect? {
        let start = max(x(for: sentence.start, viewport: viewport, width: width), 0)
        let end = min(x(for: sentence.end, viewport: viewport, width: width), width)
        guard end - start >= 1 else {
            return nil
        }
        return CGRect(x: start, y: 0, width: end - start, height: 0)
    }
}

/// Short ticks where the pause segmenter cut the original into sentences.
struct PauseTickMarks: View {
    let viewport: TimelineViewport
    let chunks: [SentenceChunk]

    var body: some View {
        Canvas { context, size in
            let color = Color.secondary.opacity(0.45)
            for time in Self.cuts(chunks) where viewport.contains(time) {
                let xPosition = SentenceBandOverlay.x(for: time, viewport: viewport, width: size.width)
                for yRange in [0 ... 4, size.height - 4 ... size.height] {
                    var tick = Path()
                    tick.move(to: CGPoint(x: xPosition, y: yRange.lowerBound))
                    tick.addLine(to: CGPoint(x: xPosition, y: yRange.upperBound))
                    context.stroke(tick, with: .color(color), lineWidth: 1)
                }
            }
        }
        .accessibilityHidden(true)
    }

    /// One cut between neighbouring chunks: the middle of the pause.
    static func cuts(_ chunks: [SentenceChunk]) -> [TimeInterval] {
        zip(chunks, chunks.dropFirst()).map { ($0.end + $1.start) / 2 }
    }
}

/// "今天 09:12", "昨天 21:40", "10月3日" (en_US: "Today 9:12 AM", "Yesterday 9:40 PM", "Oct 3").
/// The time uses the system's short time style, so it follows the user's 12/24-hour setting.
enum TakeDateText {
    static func short(
        _ date: Date,
        now: Date = Date(),
        calendar: Calendar = .current,
        locale: Locale = .current
    ) -> String {
        let time = date.formatted(
            Date.FormatStyle(
                date: .omitted,
                time: .shortened,
                locale: locale,
                calendar: calendar,
                timeZone: calendar.timeZone
            )
        )
        if calendar.isDate(date, inSameDayAs: now) {
            return String(localized: "Today \(time)", locale: locale)
        }
        let yesterday = calendar.date(byAdding: .day, value: -1, to: now) ?? now.addingTimeInterval(-86400)
        if calendar.isDate(date, inSameDayAs: yesterday) {
            return String(localized: "Yesterday \(time)", locale: locale)
        }
        return date.formatted(.dateTime.month(.abbreviated).day().locale(locale))
    }
}
