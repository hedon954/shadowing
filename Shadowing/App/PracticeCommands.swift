import SwiftUI

/// What the menu bar can reach in the focused window.
struct PracticeCommandTarget {
    let hasPractice: Bool
    let perform: @MainActor (PracticeShortcutAction) -> Void
}

extension FocusedValues {
    @Entry var practiceCommands: PracticeCommandTarget?
    /// A take is selected and nothing is recording, so ⌘⌫ can move it to the Trash.
    @Entry var practiceCanDeleteTake: Bool?
}

/// Stored choices for the subtitles: both hidden by default (listening comes first).
enum SubtitlePreferences {
    /// The one-line caption under the waveforms (toolbar "Subtitles" toggle, ⌥⌘S).
    static let captionKey = "practice.subtitleCaptionVisible"
    /// The full transcript inspector (toolbar "Full Transcript" toggle, ⌥⌘I).
    static let transcriptKey = "practice.subtitleTranscriptVisible"
}

/// The "Practice" menu lists every shortcut, so they can be found and clicked. The window's key
/// monitor handles the single keys itself, and while a text field is being edited it hands every
/// key the menu lists (including ⌥⌘S and ⌥⌘I) to the field, so the menu never acts.
struct PracticeCommands: Commands {
    @FocusedValue(\.practiceCommands) private var target
    @FocusedValue(\.practiceCanDeleteTake) private var canDeleteTake
    @AppStorage(SubtitlePreferences.captionKey) private var captionVisible = false
    @AppStorage(SubtitlePreferences.transcriptKey) private var transcriptVisible = false

    var body: some Commands {
        CommandMenu("Practice") {
            item("Play/Pause", .togglePlayback, key: .space)
            item("Record / Stop Recording", .toggleRecording, key: "r")
            item("Compare", .compare, key: "c")
            item("Replay Sentence", .replaySentence, key: .return)
            Divider()
            item("Back 5 seconds", .jumpBackward, key: .leftArrow)
            item("Forward 5 seconds", .jumpForward, key: .rightArrow)
            item("Loop", .toggleLoop, key: "l")
            item("Slower", .slower, key: "[", modifiers: .command)
            item("Faster", .faster, key: "]", modifiers: .command)
            Divider()
            Button("Delete Take") {
                target?.perform(.deleteTake)
            }
            .keyboardShortcut(.delete, modifiers: .command)
            .disabled(target == nil || canDeleteTake != true)
            Divider()
            Toggle("Subtitles", isOn: $captionVisible)
                .keyboardShortcut(PracticeShortcutKeys.subtitlesKey, modifiers: [.option, .command])
                .disabled(target?.hasPractice != true)
            Toggle("Full Transcript", isOn: $transcriptVisible)
                .keyboardShortcut(PracticeShortcutKeys.transcriptKey, modifiers: [.option, .command])
                .disabled(target?.hasPractice != true)
        }
    }

    private func item(
        _ title: LocalizedStringKey,
        _ action: PracticeShortcutAction,
        key: KeyEquivalent,
        modifiers: EventModifiers = []
    ) -> some View {
        Button(title) {
            target?.perform(action)
        }
        .keyboardShortcut(key, modifiers: modifiers)
        .disabled(target?.hasPractice != true)
    }
}
