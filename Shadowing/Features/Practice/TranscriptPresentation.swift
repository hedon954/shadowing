import AppKit

/// Music-lyrics style emphasis in the full transcript: the current sentence uses the primary
/// label color, every other sentence the secondary one. No band or marker, and the size never
/// changes, so lines don't reflow while playing.
enum TranscriptLineEmphasis: Equatable {
    case current
    case other

    /// All sentences share one size; only the color marks the current one.
    static let fontSize: CGFloat = 14

    init(cueIndex: Int, current: Int?) {
        self = cueIndex == current ? .current : .other
    }

    var color: NSColor {
        switch self {
        case .current:
            .labelColor
        case .other:
            .secondaryLabelColor
        }
    }
}

/// One piece of a cue's text as shown in the transcript. A cue may be cut into several pieces
/// at speaker labels; every piece keeps its cue index, so a click seeks to the cue and the
/// highlight covers the whole cue.
struct TranscriptRun: Equatable {
    let cueIndex: Int
    let text: String
    /// Starts on a new line because a new speaker begins here.
    let startsLine: Bool
}

/// Display-only line breaks at speaker changes ("A: …  B: …"). The stored subtitles and the
/// timing segments stay as they are.
enum SpeakerLines {
    /// "A:" or "B:" at the start or after a space, followed by a space or the end; a full-width
    /// "B：" needs no space after it.
    private static var speakerLabel: Regex<Substring> {
        /(?:^|\s)[A-Z](?::(?=\s|$)|：)/
    }

    /// Runs for one paragraph. The paragraph's first run never starts a new line.
    static func runs(for cues: [SubtitleCue], firstIndex: Int) -> [TranscriptRun] {
        var runs: [TranscriptRun] = []
        for (offset, cue) in cues.enumerated() {
            for piece in pieces(of: cue.text) {
                runs.append(
                    TranscriptRun(
                        cueIndex: firstIndex + offset,
                        text: piece.text,
                        startsLine: piece.startsWithSpeaker && !runs.isEmpty
                    )
                )
            }
        }
        return runs
    }

    /// The text cut before each speaker label, trimmed. Empty pieces are dropped.
    static func pieces(of text: String) -> [(text: String, startsWithSpeaker: Bool)] {
        var starts: [String.Index] = []
        for match in text.matches(of: speakerLabel) {
            var index = match.range.lowerBound
            if text[index].isWhitespace {
                index = text.index(after: index)
            }
            starts.append(index)
        }
        let boundaries = starts.first == text.startIndex ? starts : [text.startIndex] + starts
        var pieces: [(text: String, startsWithSpeaker: Bool)] = []
        for (position, start) in boundaries.enumerated() {
            let end = position + 1 < boundaries.count ? boundaries[position + 1] : text.endIndex
            let piece = text[start ..< end].trimmingCharacters(in: .whitespacesAndNewlines)
            if !piece.isEmpty {
                pieces.append((piece, starts.contains(start)))
            }
        }
        return pieces
    }
}

extension SubtitleSourceOption {
    /// "04-second-hand-ecommerce.srt" -> "Second hand ecommerce", like project titles.
    /// "From audio" is already a label.
    var displayName: String {
        switch kind {
        case .subtitleFile, .alignedText:
            DisplayName.cleaned(name)
        case .fromAudio:
            name
        }
    }
}

enum SubtitleSourcePicker {
    /// The source name next to "Full Transcript" only matters when there is a choice: with a
    /// single ready source the menu shrinks to an icon (its actions stay reachable).
    static func showsSourceName(_ sources: [SubtitleSourceOption]) -> Bool {
        sources.filter(\.isReady).count > 1
    }

    /// The cleaned name of the active source, or `nil` when the picker shows only its icon.
    static func shownName(sources: [SubtitleSourceOption], active: SubtitleSourceKind?) -> String? {
        guard showsSourceName(sources) else {
            return nil
        }
        return sources.first { $0.kind == active }?.displayName
    }
}
