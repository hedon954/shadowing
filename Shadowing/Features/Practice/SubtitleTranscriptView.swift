import AppKit
import SwiftUI

/// Timed subtitles that follow the playhead. The current sentence sits on a full-width accent
/// band; other sentences stay secondary. Size and weight never change, so lines don't reflow.
/// Clicking a sentence seeks to it.
struct SubtitleTranscriptView: View {
    /// Auto-scroll waits this long after the user scrolls by hand.
    static let manualScrollPause: TimeInterval = TranscriptLineEmphasis.manualScrollPause
    /// Keeps the current sentence about a third of the way down.
    static let scrollAnchor = UnitPoint(x: 0, y: 0.33)

    let transcript: SubtitleTranscript
    let playhead: TimeInterval
    let onSeek: (TimeInterval) -> Void

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var lastManualScroll: Date?
    @State private var hoveredIndex: Int?
    @State private var increaseContrast = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast

    var body: some View {
        let current = SubtitleTimeline.cueIndex(at: playhead, in: transcript.cues)
        let bandOpacity = TranscriptLineEmphasis.bandOpacity(
            dark: colorScheme == .dark,
            increaseContrast: increaseContrast
        )
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 13) {
                    ForEach(Array(transcript.paragraphs.enumerated()), id: \.offset) { _, range in
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(Array(range), id: \.self) { index in
                                TranscriptSentenceRow(
                                    cue: transcript.cues[index],
                                    cueIndex: index,
                                    isCurrent: current == index,
                                    isHovered: hoveredIndex == index,
                                    bandOpacity: bandOpacity,
                                    reduceMotion: reduceMotion,
                                    onSeek: onSeek
                                )
                                .id(index)
                                .onHover { hovering in
                                    if hovering {
                                        hoveredIndex = index
                                    } else if hoveredIndex == index {
                                        hoveredIndex = nil
                                    }
                                }
                            }
                        }
                    }
                }
                .padding(16)
            }
            .onScrollPhaseChange { _, phase in
                if phase == .tracking || phase == .interacting || phase == .decelerating {
                    lastManualScroll = Date()
                }
            }
            .onAppear {
                if let current {
                    proxy.scrollTo(current, anchor: Self.scrollAnchor)
                }
            }
            .onChange(of: current) { _, index in
                guard let index, !isPausedByUser else {
                    return
                }
                if reduceMotion {
                    proxy.scrollTo(index, anchor: Self.scrollAnchor)
                } else {
                    withAnimation(.easeInOut(duration: TranscriptLineEmphasis.bandAnimationDuration)) {
                        proxy.scrollTo(index, anchor: Self.scrollAnchor)
                    }
                }
            }
        }
        .onReceive(
            NotificationCenter.default.publisher(
                for: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification
            )
        ) { _ in
            increaseContrast = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
        }
    }

    private var isPausedByUser: Bool {
        guard let lastManualScroll else {
            return false
        }
        return Date().timeIntervalSince(lastManualScroll) < Self.manualScrollPause
    }
}

/// One timed sentence: accent band when current, faint quaternary fill on hover otherwise.
private struct TranscriptSentenceRow: View {
    let cue: SubtitleCue
    let cueIndex: Int
    let isCurrent: Bool
    let isHovered: Bool
    let bandOpacity: Double
    let reduceMotion: Bool
    let onSeek: (TimeInterval) -> Void

    var body: some View {
        sentenceText
            .font(.system(size: TranscriptLineEmphasis.fontSize, weight: .regular))
            .lineSpacing(TranscriptLineEmphasis.fontSize * 0.65)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background {
                RoundedRectangle(cornerRadius: TranscriptLineEmphasis.bandCornerRadius, style: .continuous)
                    .fill(backgroundFill)
            }
            .contentShape(Rectangle())
            .onTapGesture { onSeek(cue.start) }
            .pointerStyle(.link)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(verbatim: cue.text))
            .accessibilityHint("Click a sentence to jump there")
            .accessibilityAddTraits(.isButton)
            .accessibilityAddTraits(isCurrent ? .isSelected : [])
            .accessibilityAction { onSeek(cue.start) }
            .animation(
                reduceMotion ? nil : .easeInOut(duration: TranscriptLineEmphasis.bandAnimationDuration),
                value: isCurrent
            )
    }

    private var backgroundFill: Color {
        if isCurrent {
            Color.accentColor.opacity(bandOpacity)
        } else if isHovered {
            Color(nsColor: .quaternarySystemFill)
        } else {
            Color.clear
        }
    }

    /// Speaker changes inside a cue still wrap to a new line (display only).
    private var sentenceText: Text {
        let emphasis = TranscriptLineEmphasis(cueIndex: cueIndex, current: isCurrent ? cueIndex : nil)
        let runs = SpeakerLines.runs(for: [cue], firstIndex: cueIndex)
        return runs.enumerated().reduce(Text(verbatim: "")) { text, item in
            let run = item.element
            let piece = Text(verbatim: run.text)
                .foregroundStyle(Color(nsColor: emphasis.color))
            guard item.offset > 0 else {
                return piece
            }
            return text + Text(verbatim: run.startsLine ? "\n" : " ") + piece
        }
    }
}
