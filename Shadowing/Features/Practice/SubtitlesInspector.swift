import SwiftUI

/// Right-hand inspector titled "Subtitles": timed subtitles that follow playback, or the
/// attached text when it can't be timed.
struct SubtitlesInspector: View {
    @ObservedObject var viewModel: PracticeViewModel
    @ObservedObject var subtitles: SubtitlesViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            Divider()
            status
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            footer
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Practice script")
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text("Subtitles")
                .font(.system(size: 13, weight: .bold))
            Spacer(minLength: 8)
            SubtitleSourceMenu(viewModel: viewModel, subtitles: subtitles)
        }
    }

    @ViewBuilder
    private var status: some View {
        switch subtitles.display {
        case let .working(work, _):
            SubtitleWorkBox(work: work)
                .padding(.horizontal, 12)
                .padding(.top, 10)
        case .plainText(_, notice: .some):
            SubtitleFailureNotice(detail: subtitles.failureDetail)
                .padding(.horizontal, 16)
                .padding(.top, 10)
        case .loading, .empty, .plainText, .timed:
            EmptyView()
        }
    }

    @ViewBuilder
    private var content: some View {
        switch subtitles.display {
        case .loading:
            Color.clear
        case .empty:
            SubtitlesEmptyState(
                isEnabled: !viewModel.controlsLocked && subtitles.canAddFiles,
                onAdd: subtitles.addSubtitlesOrText
            )
        case let .plainText(text, _), let .working(_, text):
            PlainSubtitleText(text: text)
        case let .timed(transcript):
            SubtitleTranscriptView(
                transcript: transcript,
                playhead: viewModel.playhead,
                onSeek: viewModel.seek(to:)
            )
        }
    }

    @ViewBuilder
    private var footer: some View {
        if let hint = footerHint {
            VStack(spacing: 0) {
                Divider()
                Text(hint)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 9)
            }
        }
    }

    private var footerHint: LocalizedStringKey? {
        switch subtitles.display {
        case .timed:
            "Click a sentence to jump there"
        case .working:
            "Highlighting starts when recognition finishes"
        case .plainText(_, notice: .some):
            "Pick another source from the menu above"
        case .loading, .empty, .plainText:
            nil
        }
    }
}

private struct SubtitleSourceMenu: View {
    @ObservedObject var viewModel: PracticeViewModel
    @ObservedObject var subtitles: SubtitlesViewModel

    var body: some View {
        Menu {
            if !subtitles.sources.isEmpty {
                Section("Subtitle Source") {
                    ForEach(subtitles.sources) { option in
                        Toggle(isOn: selection(option.kind)) {
                            Text(verbatim: option.name)
                            Text(option.kind.detail)
                        }
                    }
                }
            }
            Button("Add Subtitle File…", action: subtitles.addSubtitleFile)
                .disabled(!subtitles.canAddFiles)
                .accessibilityLabel("Attach subtitle file")
            Button("Add Text…", action: viewModel.attachScript)
                .accessibilityLabel(
                    viewModel.scriptText == nil
                        ? "Attach script text file"
                        : "Replace script text file"
                )
        } label: {
            Group {
                if let name = subtitles.activeSourceName {
                    Text(verbatim: name)
                } else {
                    Text("None")
                }
            }
            .lineLimit(1)
            .truncationMode(.middle)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .foregroundStyle(.secondary)
        .disabled(viewModel.controlsLocked)
        .accessibilityLabel("Subtitle Source")
    }

    private func selection(_ kind: SubtitleSourceKind) -> Binding<Bool> {
        Binding {
            subtitles.activeSource == kind
        } set: { isOn in
            if isOn {
                subtitles.select(kind)
            }
        }
    }
}

extension SubtitleSourceKind {
    var detail: LocalizedStringKey {
        switch self {
        case .subtitleFile:
            "Subtitle file"
        case .alignedText:
            "Aligned text"
        }
    }
}

private struct SubtitleWorkBox: View {
    let work: SubtitleWork

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(title)
                    .lineLimit(1)
                Spacer(minLength: 4)
                Text(work.fraction, format: .percent.precision(.fractionLength(0)))
                    .monospacedDigit()
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            ProgressView(value: min(max(work.fraction, 0), 1))
                .progressViewStyle(.linear)
                .controlSize(.small)
            Text("Runs on this Mac. Nothing is uploaded.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(8)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 6))
        .accessibilityElement(children: .combine)
    }

    private var title: LocalizedStringKey {
        switch work.phase {
        case .downloadingModel:
            "Downloading English speech model (one time)…"
        case .aligning:
            "Aligning text…"
        }
    }
}

private struct SubtitleFailureNotice: View {
    let detail: String?

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.circle.fill")
                .foregroundStyle(.orange)
                .accessibilityHidden(true)
            Text("Can't align. Showing plain text.")
                .foregroundStyle(.secondary)
        }
        .font(.caption)
        .help(detail ?? "")
        .accessibilityElement(children: .combine)
    }
}

private struct PlainSubtitleText: View {
    let text: String

    var body: some View {
        ScrollView {
            Text(text)
                .font(.system(size: 13))
                .lineSpacing(13 * 0.65)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
                .padding(16)
        }
    }
}

private struct SubtitlesEmptyState: View {
    let isEnabled: Bool
    let onAdd: () -> Void

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "doc")
                .font(.system(size: 28))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text("No subtitles yet")
                .font(.headline)
            Text(
                """
                Add a subtitle or text file if you have one. \
                If not, generate subtitles from the audio on this Mac.
                """
            )
            .font(.callout)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            Button("Add Subtitles or Text…", action: onAdd)
                .disabled(!isEnabled)
                .accessibilityLabel("Attach script text file")
                .padding(.top, 4)
            Text("Supports .srt, .vtt, .lrc and .txt")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
