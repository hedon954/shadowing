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
                // In a narrow column the gray hint drops first; the segments and the button stay.
                ViewThatFits(in: .horizontal) {
                    controls(showsHint: true)
                    controls(showsHint: false)
                    // The minimum window with the transcript open: tighter segments, no key cap.
                    controls(showsHint: false, compact: true)
                    // Longer languages (English) at that width: Original / Mine / Both first...
                    controls(showsHint: false, compact: true, shortLabels: true)
                    // ...and only then does the button keep just its icon.
                    controls(showsHint: false, compact: true, shortLabels: true, iconOnly: true)
                }
            }
        }
        .frame(minHeight: 30)
    }

    private func controls(
        showsHint: Bool,
        compact: Bool = false,
        shortLabels: Bool = false,
        iconOnly: Bool = false
    ) -> some View {
        HStack(spacing: compact ? 6 : 12) {
            CompareModePicker(
                mode: viewModel.compareMode,
                onSelect: viewModel.setCompareMode,
                compact: compact,
                shortLabels: shortLabels
            )
            .fixedSize()
            .disabled(viewModel.controlsLocked)
            if showsHint, let hint = sentenceHint {
                Text(hint)
                    .font(.system(size: 12).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .fixedSize()
            }
            Spacer(minLength: 8)
            CompareButton(
                isComparing: viewModel.comparison != nil,
                showsKey: !compact,
                showsTitle: !iconOnly,
                action: viewModel.compare
            )
            .fixedSize()
            .disabled(!canCompare)
        }
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
    var compact = false
    /// "Both" for "Original then mine" in English; zh-Hans keeps 先原音再我的.
    var shortLabels = false

    var body: some View {
        HStack(spacing: 2) {
            ForEach(CompareMode.allCases) { option in
                Button {
                    onSelect(option)
                } label: {
                    Text(shortLabels ? Self.shortTitle(for: option) : Self.title(for: option))
                        .font(.system(size: 12, weight: option == mode ? .semibold : .medium))
                        .foregroundStyle(option == mode ? .primary : .secondary)
                        .padding(.horizontal, compact ? 6 : 12)
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
                .accessibilityLabel(Text(Self.title(for: option)))
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

    static func shortTitle(for mode: CompareMode) -> LocalizedStringKey {
        mode == .originalThenMine ? "Compare mode both short" : title(for: mode)
    }
}

/// The accent "▶ 对比播放  C" capsule. The gray C is the single-key shortcut.
struct CompareButton: View {
    let isComparing: Bool
    var showsKey = true
    var showsTitle = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            if showsTitle {
                titled
            } else {
                // Icon only: a filled accent circle the height of the titled capsule.
                icon
                    .frame(width: 28, height: 28)
                    .background(Color.accentColor, in: Circle())
                    .contentShape(Circle())
            }
        }
        .buttonStyle(.plain)
        .help("Play the selected sentence: the original, your take, or both (C)")
        .accessibilityLabel(isComparing ? "Stop Comparing" : "Compare")
        .accessibilityHint("Shortcut: C")
    }

    private var icon: some View {
        Image(systemName: isComparing ? "stop.fill" : "play.fill")
            .font(.system(size: 9, weight: .bold))
            .foregroundStyle(.white)
    }

    private var titled: some View {
        HStack(spacing: 7) {
            icon
            Text(isComparing ? "Stop Comparing" : "Compare")
                .font(.system(size: 12.5, weight: .semibold))
            if showsKey {
                ShortcutKeyHint(key: "C", onAccent: true)
            }
        }
        .frame(minHeight: 16)
        .foregroundStyle(.white)
        .padding(.leading, showsKey ? 14 : 10)
        .padding(.trailing, showsKey ? 8 : 10)
        .padding(.vertical, 6)
        .background(Color.accentColor, in: Capsule())
        .contentShape(Capsule())
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
