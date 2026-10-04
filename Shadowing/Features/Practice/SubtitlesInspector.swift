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
        if let error = subtitles.generationError {
            SubtitleFailureNotice(message: "Can't generate subtitles.", detail: error)
                .padding(.horizontal, 16)
                .padding(.top, 10)
        } else {
            displayStatus
        }
    }

    @ViewBuilder
    private var displayStatus: some View {
        switch subtitles.display {
        case let .working(work, _):
            SubtitleWorkBox(work: work)
                .padding(.horizontal, 12)
                .padding(.top, 10)
        case .plainText(_, notice: .some):
            SubtitleFailureNotice(message: "Can't align. Showing plain text.", detail: subtitles.failureDetail)
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
                canGenerate: subtitles.canGenerate && !subtitles.isGenerating,
                onGenerate: subtitles.generateFromAudio,
                onAdd: subtitles.addSubtitlesOrText
            )
        case let .plainText(text, _):
            PlainSubtitleText(text: text, isGrowing: false)
        case let .working(work, text):
            PlainSubtitleText(text: text, isGrowing: work.phase == .recognizing)
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
        if subtitles.generationError != nil, subtitles.exportableCues == nil {
            return "Pick another source from the menu above"
        }
        return switch subtitles.display {
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
                            Text(option.isReady ? option.kind.detail : "Not generated")
                        }
                        .disabled(!option.isReady && subtitles.isGenerating)
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
            Button(action: subtitles.generateFromAudio) {
                Text("Generate Subtitles from Audio")
                if !SubtitleAvailability.isGenerationSupported {
                    Text("Requires macOS 26")
                }
            }
            .disabled(!subtitles.canGenerate || subtitles.isGenerating)
            .accessibilityLabel("Generate Subtitles from Audio")
            Divider()
            Button("Export .srt…", action: subtitles.exportSRT)
                .disabled(subtitles.exportableCues == nil)
                .accessibilityLabel("Export subtitles as SRT file")
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
        case .fromAudio:
            "Generated"
        }
    }
}

enum SubtitleAvailability {
    /// On-device speech recognition (`SpeechAnalyzer`) needs macOS 26.
    static var isGenerationSupported: Bool {
        if #available(macOS 26, *) {
            return true
        }
        return false
    }
}

private struct SubtitleWorkBox: View {
    let work: SubtitleWork

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                // Long statuses such as the model download wrap to a second line.
                Text(title)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                Spacer(minLength: 4)
                Text(work.fraction, format: .percent.precision(.fractionLength(0)))
                    .monospacedDigit()
                    .layoutPriority(1)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            ProgressView(value: min(max(work.fraction, 0), 1))
                .progressViewStyle(.linear)
                .controlSize(.small)
            Text(note)
                .font(.caption)
                .foregroundStyle(.secondary)
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
        case .recognizing:
            "Recognizing speech…"
        }
    }

    private var note: LocalizedStringKey {
        work.phase == .recognizing
            ? "Runs on this Mac. Nothing is uploaded. Text appears below as it's recognized."
            : "Runs on this Mac. Nothing is uploaded."
    }
}

private struct SubtitleFailureNotice: View {
    let message: LocalizedStringKey
    let detail: String?

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.circle.fill")
                .foregroundStyle(.orange)
                .accessibilityHidden(true)
            Text(message)
                .foregroundStyle(.secondary)
        }
        .font(.caption)
        .help(detail ?? "")
        .accessibilityElement(children: .combine)
    }
}

private struct PlainSubtitleText: View {
    let text: String
    /// Recognition is still adding text.
    let isGrowing: Bool

    private var paragraphs: [String] {
        // Blank lines separate paragraphs; single line breaks stay inside one.
        text.replacingOccurrences(of: "\r\n", with: "\n")
            .replacing(/\n[ \t]*\n\s*/, with: "\u{0}")
            .split(separator: "\u{0}")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 13) {
                // Same paragraph spacing as the timed transcript.
                ForEach(Array(paragraphs.enumerated()), id: \.offset) { _, paragraph in
                    Text(verbatim: paragraph)
                        .font(.system(size: 13))
                        .lineSpacing(13 * 0.65)
                        .textSelection(.enabled)
                }
                if isGrowing {
                    Text(verbatim: "…")
                        .foregroundStyle(.tertiary)
                        .accessibilityHidden(true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
        }
    }
}

private struct SubtitlesEmptyState: View {
    let isEnabled: Bool
    let canGenerate: Bool
    let onGenerate: () -> Void
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
            VStack(spacing: 8) {
                Button(action: onGenerate) {
                    Text("Generate Subtitles from Audio")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!isEnabled || !canGenerate)
                .accessibilityLabel("Generate Subtitles from Audio")
                if !SubtitleAvailability.isGenerationSupported {
                    Text("Requires macOS 26")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Button(action: onAdd) {
                    Text("Add Subtitles or Text…")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .disabled(!isEnabled)
                .accessibilityLabel("Attach script text file")
            }
            .padding(.top, 4)
            Text("Supports .srt, .vtt, .lrc and .txt")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
