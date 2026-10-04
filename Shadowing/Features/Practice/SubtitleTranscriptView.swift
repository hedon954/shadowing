import SwiftUI

/// Timed subtitles that follow the playhead. Played sentences are secondary, the current one
/// sits on an accent tint, upcoming ones are primary. The weight never changes, so lines
/// don't reflow. Clicking a sentence seeks to it.
struct SubtitleTranscriptView: View {
    /// Auto-scroll waits this long after the user scrolls by hand.
    static let manualScrollPause: TimeInterval = 4
    /// Keeps the current sentence about a third of the way down.
    static let scrollAnchor = UnitPoint(x: 0, y: 0.33)

    let transcript: SubtitleTranscript
    let playhead: TimeInterval
    let onSeek: (TimeInterval) -> Void

    @Environment(\.colorScheme) private var colorScheme
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
                            progress: ParagraphProgress(range: range, current: current),
                            highlightOpacity: colorScheme == .dark ? 0.22 : 0.12,
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

enum ParagraphProgress: Equatable {
    case upcoming
    case played
    case current(Int)

    init(range: Range<Int>, current: Int?) {
        guard let current, current >= range.lowerBound else {
            self = .upcoming
            return
        }
        self = current >= range.upperBound ? .played : .current(current)
    }

    func isPlayed(_ index: Int) -> Bool {
        switch self {
        case .upcoming:
            false
        case .played:
            true
        case let .current(current):
            index < current
        }
    }
}

/// Marks which cue a run of text belongs to, for highlighting and hit testing.
private struct CueRun: TextAttribute {
    let index: Int
}

private struct SubtitleParagraph: View, Equatable {
    let cues: [SubtitleCue]
    let firstIndex: Int
    let progress: ParagraphProgress
    let highlightOpacity: Double
    let onSeek: (TimeInterval) -> Void

    nonisolated static func == (lhs: SubtitleParagraph, rhs: SubtitleParagraph) -> Bool {
        lhs.firstIndex == rhs.firstIndex
            && lhs.progress == rhs.progress
            && lhs.highlightOpacity == rhs.highlightOpacity
            && lhs.cues == rhs.cues
    }

    var body: some View {
        paragraphText
            .font(.system(size: 13))
            .lineSpacing(13 * 0.65)
            .frame(maxWidth: .infinity, alignment: .leading)
            .backgroundPreferenceValue(Text.LayoutKey.self) { layouts in
                GeometryReader { proxy in
                    ForEach(Array(highlightRects(layouts, proxy: proxy).enumerated()), id: \.offset) { _, rect in
                        RoundedRectangle(cornerRadius: 4)
                            .fill(Color.accentColor.opacity(highlightOpacity))
                            .frame(width: rect.width, height: rect.height)
                            .position(x: rect.midX, y: rect.midY)
                    }
                }
            }
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

    private var paragraphText: Text {
        cues.enumerated().reduce(Text(verbatim: "")) { text, item in
            let index = firstIndex + item.offset
            let sentence = Text(verbatim: item.element.text)
                .foregroundStyle(progress.isPlayed(index) ? HierarchicalShapeStyle.secondary : .primary)
                .customAttribute(CueRun(index: index))
            return item.offset == 0 ? sentence : text + Text(verbatim: " ") + sentence
        }
    }

    /// One rounded rectangle per line the current cue occupies.
    private func highlightRects(_ layouts: Text.LayoutKey.Value, proxy: GeometryProxy) -> [CGRect] {
        guard case let .current(current) = progress else {
            return []
        }
        var rects: [CGRect] = []
        for anchored in layouts {
            let origin = proxy[anchored.origin]
            for line in anchored.layout {
                let bounds = line
                    .filter { $0[CueRun.self]?.index == current }
                    .map(\.typographicBounds.rect)
                guard let first = bounds.first else {
                    continue
                }
                let union = bounds.dropFirst().reduce(first) { $0.union($1) }
                rects.append(union.offsetBy(dx: origin.x, dy: origin.y).insetBy(dx: -3, dy: -1))
            }
        }
        return rects
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
