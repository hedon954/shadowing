import SwiftUI

/// Under the card: what Compare plays (原音 / 我的 / 先原音再我的), the sentence it is pinned
/// to, and the Compare button. While recording it becomes one red status line.
struct CompareBar: View {
    @ObservedObject var viewModel: PracticeViewModel

    private var isRecording: Bool {
        viewModel.recordingPresentation.locksPracticeControls
    }

    var body: some View {
        HStack(spacing: 12) {
            if isRecording {
                recordingStatus
            } else {
                CompareModePicker(mode: viewModel.compareMode, onSelect: viewModel.setCompareMode)
                    .disabled(viewModel.controlsLocked)
                if let hint = sentenceHint {
                    Text(hint)
                        .font(.system(size: 12).monospacedDigit())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                CompareButton(isComparing: viewModel.comparison != nil, action: viewModel.compare)
                    .disabled(!canCompare)
            }
        }
        .frame(minHeight: 30)
    }

    private var canCompare: Bool {
        viewModel.comparison != nil || (!viewModel.controlsLocked && viewModel.currentSentence != nil)
    }

    private var sentenceHint: String? {
        guard let sentence = viewModel.currentSentence else {
            return nil
        }
        let range = "\(ClockText.duration(sentence.start))–\(ClockText.duration(sentence.end))"
        return String(localized: "Plays only the selected sentence · \(range)")
    }

    private var recordingStatus: some View {
        HStack(spacing: 10) {
            Text("● Recording Take \(viewModel.recordingTakeNumber)")
                .fontWeight(.semibold)
                .foregroundStyle(.red)
            Text("· Speak along with the original. It lines up above when you stop.")
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .font(.system(size: 12))
        .accessibilityElement(children: .combine)
    }
}

/// A compact three-way segmented control styled like the mockup (selected segment raised).
struct CompareModePicker: View {
    let mode: CompareMode
    let onSelect: (CompareMode) -> Void

    var body: some View {
        HStack(spacing: 2) {
            ForEach(CompareMode.allCases) { option in
                Button {
                    onSelect(option)
                } label: {
                    Text(Self.title(for: option))
                        .font(.system(size: 12, weight: option == mode ? .semibold : .medium))
                        .foregroundStyle(option == mode ? .primary : .secondary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 5)
                        .background {
                            if option == mode {
                                RoundedRectangle(cornerRadius: 7, style: .continuous)
                                    .fill(Color(nsColor: .controlBackgroundColor))
                                    .shadow(color: .black.opacity(0.12), radius: 1, y: 1)
                            }
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(option == mode ? .isSelected : [])
            }
        }
        .padding(2)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Compare mode")
    }

    static func title(for mode: CompareMode) -> LocalizedStringKey {
        switch mode {
        case .original:
            "Original"
        case .mine:
            "Mine"
        case .originalThenMine:
            "Original then mine"
        }
    }
}

/// The accent "▶ 对比播放  C" capsule. The gray C is the single-key shortcut.
struct CompareButton: View {
    let isComparing: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                Image(systemName: isComparing ? "stop.fill" : "play.fill")
                    .font(.system(size: 9, weight: .bold))
                Text(isComparing ? "Stop Comparing" : "Compare")
                    .font(.system(size: 12.5, weight: .semibold))
                ShortcutKeyHint(key: "C", onAccent: true)
            }
            .foregroundStyle(.white)
            .padding(.leading, 14)
            .padding(.trailing, 8)
            .padding(.vertical, 6)
            .background(Color.accentColor, in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help("Play the selected sentence: the original, your take, or both (C)")
        .accessibilityLabel(isComparing ? "Stop Comparing" : "Compare")
        .accessibilityHint("Shortcut: C")
    }
}

/// A small gray key cap shown inside a button: "C", "R", "Space", "↩".
struct ShortcutKeyHint: View {
    let key: String
    var onAccent = false

    var body: some View {
        Text(verbatim: key)
            .font(.system(size: 10, weight: .semibold).monospaced())
            .foregroundStyle(onAccent ? AnyShapeStyle(.white.opacity(0.7)) : AnyShapeStyle(.tertiary))
            .padding(.horizontal, 4)
            .frame(minWidth: 16, minHeight: 16)
            .background(
                onAccent ? Color.white.opacity(0.18) : Color.primary.opacity(0.06),
                in: RoundedRectangle(cornerRadius: 4, style: .continuous)
            )
            .accessibilityHidden(true)
    }
}
