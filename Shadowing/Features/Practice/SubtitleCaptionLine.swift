import SwiftUI

/// v8: with subtitles on, only the line being spoken is shown under the waveforms.
struct SubtitleCaptionLine: View {
    @ObservedObject var viewModel: PracticeViewModel
    @ObservedObject var subtitles: SubtitlesViewModel

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            if let speaker = caption?.speaker {
                Text(verbatim: speaker)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            Text(verbatim: caption?.text ?? "")
                .font(.system(size: 15))
                .lineSpacing(15 * 0.45 - 4)
                .foregroundStyle(caption == nil ? .secondary : .primary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
                .overlay(alignment: .leading) {
                    if caption == nil {
                        Text(emptyText)
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                    }
                }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 10))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Current subtitle")
        .animation(nil, value: caption?.text)
    }

    private var caption: (speaker: String?, text: String)? {
        guard let cue = viewModel.currentCaption else {
            return nil
        }
        return SpeakerLine.split(cue.text)
    }

    private var emptyText: LocalizedStringKey {
        switch subtitles.display {
        case .loading:
            "Loading subtitles…"
        case .plainText, .working:
            "Subtitles have no timing yet"
        case .empty, .timed:
            "No subtitles yet"
        }
    }
}

/// "B: There is…" -> ("B", "There is…"). Short labels only, so a colon in a sentence stays.
enum SpeakerLine {
    static func split(_ text: String) -> (speaker: String?, text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard let colon = trimmed.firstIndex(where: { $0 == ":" || $0 == "：" }) else {
            return (nil, trimmed)
        }
        let label = trimmed[..<colon].trimmingCharacters(in: .whitespaces)
        guard !label.isEmpty, label.count <= 12, !label.contains(" ") || label.count <= 3 else {
            return (nil, trimmed)
        }
        let rest = trimmed[trimmed.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        return rest.isEmpty ? (nil, trimmed) : (label, rest)
    }
}
