import AppKit
import SwiftUI

/// Timed subtitles that follow the playhead, Music-lyrics style: the current sentence is
/// primary, every other sentence secondary, with no band or marker. Size and weight never
/// change, so lines don't reflow. Clicking a sentence seeks to it.
struct SubtitleTranscriptView: View {
    /// Auto-scroll waits this long after the user scrolls by hand.
    static let manualScrollPause: TimeInterval = 4
    /// Keeps the current sentence about a third of the way down.
    static let scrollAnchor = UnitPoint(x: 0, y: 0.33)

    let transcript: SubtitleTranscript
    let playhead: TimeInterval
    let onSeek: (TimeInterval) -> Void

    @State private var lastManualScroll: Date?

    var body: some View {
        let current = SubtitleTimeline.cueIndex(at: playhead, in: transcript.cues)
        let currentParagraph = current.flatMap { index in
            transcript.paragraphs.firstIndex { $0.contains(index) }
        }
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 13) {
                    ForEach(Array(transcript.paragraphs.enumerated()), id: \.offset) { offset, range in
                        SubtitleParagraph(
                            cues: Array(transcript.cues[range]),
                            firstIndex: range.lowerBound,
                            current: current.flatMap { range.contains($0) ? $0 : nil },
                            onSeek: onSeek
                        )
                        .equatable()
                        .id(offset)
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
                if let currentParagraph {
                    proxy.scrollTo(currentParagraph, anchor: Self.scrollAnchor)
                }
            }
            .onChange(of: currentParagraph) { _, paragraph in
                guard let paragraph, !isPausedByUser else {
                    return
                }
                withAnimation(.easeInOut(duration: 0.35)) {
                    proxy.scrollTo(paragraph, anchor: Self.scrollAnchor)
                }
            }
        }
    }

    private var isPausedByUser: Bool {
        guard let lastManualScroll else {
            return false
        }
        return Date().timeIntervalSince(lastManualScroll) < Self.manualScrollPause
    }
}

/// Marks which cue a run of text belongs to, for hit testing.
private struct CueRun: TextAttribute {
    let index: Int
}

private struct SubtitleParagraph: View, Equatable {
    let cues: [SubtitleCue]
    let firstIndex: Int
    /// The current cue when it is in this paragraph.
    let current: Int?
    let onSeek: (TimeInterval) -> Void

    nonisolated static func == (lhs: SubtitleParagraph, rhs: SubtitleParagraph) -> Bool {
        lhs.firstIndex == rhs.firstIndex
            && lhs.current == rhs.current
            && lhs.cues == rhs.cues
    }

    var body: some View {
        paragraphText
            .font(.system(size: TranscriptLineEmphasis.fontSize))
            .lineSpacing(TranscriptLineEmphasis.fontSize * 0.65)
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlayPreferenceValue(Text.LayoutKey.self) { layouts in
                GeometryReader { proxy in
                    Color.clear
                        .contentShape(Rectangle())
                        .gesture(
                            SpatialTapGesture().onEnded { value in
                                if let index = cueIndex(at: value.location, in: layouts, proxy: proxy) {
                                    onSeek(cues[index - firstIndex].start)
                                }
                            }
                        )
                        .pointerStyle(.link)
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(verbatim: cues.map(\.text).joined(separator: " ")))
            .accessibilityHint("Click a sentence to jump there")
            .accessibilityAddTraits(.isButton)
            .accessibilityAction {
                if let first = cues.first {
                    onSeek(first.start)
                }
            }
    }

    /// Each cue's runs share its color; a speaker change starts a new line (display only).
    private var paragraphText: Text {
        SpeakerLines.runs(for: cues, firstIndex: firstIndex).enumerated().reduce(Text(verbatim: "")) { text, item in
            let run = item.element
            let emphasis = TranscriptLineEmphasis(cueIndex: run.cueIndex, current: current)
            let piece = Text(verbatim: run.text)
                // Explicit system label colors on each joined `Text` run, so a run never
                // depends on how a hierarchical style resolves inside the inspector.
                .foregroundStyle(Color(nsColor: emphasis.color))
                .customAttribute(CueRun(index: run.cueIndex))
            guard item.offset > 0 else {
                return piece
            }
            return text + Text(verbatim: run.startsLine ? "\n" : " ") + piece
        }
    }

    /// The cue under the pointer, or the nearest one on the clicked line.
    private func cueIndex(at point: CGPoint, in layouts: Text.LayoutKey.Value, proxy: GeometryProxy) -> Int? {
        for anchored in layouts {
            let origin = proxy[anchored.origin]
            for line in anchored.layout {
                let lineRect = line.typographicBounds.rect.offsetBy(dx: origin.x, dy: origin.y)
                guard point.y >= lineRect.minY - 5, point.y <= lineRect.maxY + 5 else {
                    continue
                }
                var nearest: (index: Int, distance: CGFloat)?
                for run in line {
                    guard let index = run[CueRun.self]?.index else {
                        continue
                    }
                    let rect = run.typographicBounds.rect.offsetBy(dx: origin.x, dy: origin.y)
                    let distance = point.x < rect.minX ? rect.minX - point.x : max(point.x - rect.maxX, 0)
                    if nearest.map({ distance < $0.distance }) ?? true {
                        nearest = (index, distance)
                    }
                }
                if let nearest {
                    return nearest.index
                }
            }
        }
        return nil
    }
}
