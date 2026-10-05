import SwiftUI

/// v9 toolbar: the window title carries the file name and "2:10 · 3 takes"; on the right, the
/// one-line subtitle (⌥⌘S) and the full transcript inspector (⌥⌘I) are standard toggles.
/// The shortcuts live in the Practice menu.
struct PracticeToolbar: ToolbarContent {
    @Binding var isCaptionVisible: Bool
    @Binding var isTranscriptVisible: Bool

    var body: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Toggle(isOn: $isCaptionVisible) {
                Label("Subtitles", systemImage: "captions.bubble")
            }
            .toggleStyle(.button)
            .help(isCaptionVisible ? "Hide Subtitles (⌥⌘S)" : "Show Subtitles (⌥⌘S)")
            Toggle(isOn: $isTranscriptVisible) {
                Label("Full Transcript", systemImage: "sidebar.right")
            }
            .toggleStyle(.button)
            .help(isTranscriptVisible ? "Hide Full Transcript (⌥⌘I)" : "Show Full Transcript (⌥⌘I)")
        }
    }
}

/// The window subtitle under the file name.
enum PracticeTitleText {
    /// "2:10 · 3 takes", or just "2:12" before the first take.
    static func summary(duration: TimeInterval, takeCount: Int) -> String {
        let length = ClockText.duration(duration)
        guard takeCount > 0 else {
            return length
        }
        return length + " · " + String(localized: "\(takeCount) takes")
    }

    /// The summary, or what recording is doing right now.
    static func subtitle(for status: PracticeHeaderStatus, duration: TimeInterval) -> String {
        switch status {
        case let .takes(count, _):
            summary(duration: duration, takeCount: count)
        case .checkingMicrophone:
            String(localized: "Checking microphone…")
        case let .countingDown(_, remainingSeconds):
            String(localized: "Recording starts in \(remainingSeconds)")
        case let .recording(takeNumber):
            "● " + String(localized: "Recording Take \(takeNumber)")
        case .saving:
            String(localized: "Saving recording…")
        }
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
