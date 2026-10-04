import SwiftUI

/// Right-hand inspector titled "Subtitles". Shows the attached text next to the waveform.
struct SubtitlesInspector: View {
    @ObservedObject var viewModel: PracticeViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            Divider()
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
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
            sourceMenu
        }
    }

    private var sourceMenu: some View {
        Menu {
            Button(viewModel.scriptText == nil ? "Add Text…" : "Replace Text…") {
                viewModel.attachScript()
            }
            .accessibilityLabel(
                viewModel.scriptText == nil
                    ? "Attach script text file"
                    : "Replace script text file"
            )
        } label: {
            Group {
                if let name = viewModel.project.scriptDisplayName {
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

    @ViewBuilder
    private var content: some View {
        if let scriptText = viewModel.scriptText, !scriptText.isEmpty {
            ScrollView {
                Text(scriptText)
                    .font(.system(size: 13))
                    .lineSpacing(13 * 0.65)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                    .padding(16)
            }
        } else {
            SubtitlesEmptyState(
                isEnabled: !viewModel.controlsLocked,
                onAddText: viewModel.attachScript
            )
        }
    }
}

private struct SubtitlesEmptyState: View {
    let isEnabled: Bool
    let onAddText: () -> Void

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
            Button("Add Subtitles or Text…", action: onAddText)
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
