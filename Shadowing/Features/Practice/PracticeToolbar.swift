import SwiftUI

/// v6 toolbar: only the title and the subtitles toggle; playback lives in `PracticeControlBar`.
struct PracticeToolbar: ToolbarContent {
    let viewModel: PracticeViewModel
    @Binding var isCaptionVisible: Bool

    var body: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            PracticeToolbarTitle(viewModel: viewModel)
        }
        if #available(macOS 26.0, *) {
            ToolbarSpacer(.flexible)
        }
        ToolbarItem(placement: .primaryAction) {
            SubtitlesToggleButton(isOn: $isCaptionVisible)
        }
    }
}

private struct PracticeToolbarTitle: View {
    @ObservedObject var viewModel: PracticeViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(verbatim: DisplayName.cleaned(viewModel.project.sourceDisplayName))
                .font(.system(size: 14, weight: .bold))
                .lineLimit(1)
                .truncationMode(.tail)
            subtitle
                .font(.system(size: 11))
                .lineLimit(1)
        }
        .frame(maxWidth: 520, alignment: .leading)
        .help(viewModel.project.sourceDisplayName)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var subtitle: some View {
        switch viewModel.headerStatus {
        case let .takes(count, _):
            Text(verbatim: PracticeTitleText.summary(duration: viewModel.project.duration, takeCount: count))
                .foregroundStyle(.secondary)
        case .checkingMicrophone:
            Text("Checking microphone…")
                .foregroundStyle(.secondary)
        case let .countingDown(_, remainingSeconds):
            Text("Recording starts in \(remainingSeconds)")
                .foregroundStyle(.red)
        case let .recording(takeNumber):
            (Text(verbatim: "● ") + Text("Recording Take \(takeNumber)"))
                .foregroundStyle(.red)
        case .saving:
            Text("Saving recording…")
                .foregroundStyle(.secondary)
        }
    }
}

/// "2:10 · 3 takes", or just "2:12" before the first take.
enum PracticeTitleText {
    static func summary(duration: TimeInterval, takeCount: Int) -> String {
        let length = ClockText.duration(duration)
        guard takeCount > 0 else {
            return length
        }
        return length + " · " + String(localized: "\(takeCount) takes")
    }
}

/// The "字幕 / Subtitles" badge at the top right; shows one subtitle line under the waveforms.
private struct SubtitlesToggleButton: View {
    @Binding var isOn: Bool

    var body: some View {
        Button {
            isOn.toggle()
        } label: {
            Text("Subtitles badge")
                .font(.system(size: 10, weight: .bold))
                .tracking(0.3)
                .padding(.horizontal, 4)
                .padding(.vertical, 1)
                .overlay {
                    RoundedRectangle(cornerRadius: 3)
                        .strokeBorder(lineWidth: 1.3)
                }
                .foregroundStyle(isOn ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
        }
        .accessibilityLabel(isOn ? "Hide Subtitles" : "Show Subtitles")
        .accessibilityAddTraits(isOn ? .isSelected : [])
        .help(isOn ? "Hide Subtitles" : "Show Subtitles")
    }
}

enum PracticeRateText {
    static func label(_ rate: Double) -> String {
        rate == 1 ? "1.0×" : "\(rate.formatted())×"
    }
}

extension FormatStyle where Self == Date.FormatStyle {
    /// "Oct 4" / "10月4日", following the user's language.
    static var practiceDay: Date.FormatStyle {
        .dateTime.month(.abbreviated).day()
    }

    /// "Oct 4, 20:10" / "10月4日 20:10", following the user's language.
    static var practiceDayTime: Date.FormatStyle {
        .dateTime.month(.abbreviated).day().hour().minute()
    }
}
