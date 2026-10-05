import AppKit
import SwiftUI

enum PracticeShortcutAction: Equatable, Sendable, CaseIterable {
    case togglePlayback
    case toggleRecording
    case compare
    case replaySentence
    case toggleLoop
    case jumpBackward
    case jumpForward
    case slower
    case faster
    case openAudio
    case deleteTake
}

/// The window-level keys. Single keys never fire while a text field is being edited.
enum PracticeShortcutKeys {
    static let space: UInt16 = 49
    static let returnKey: UInt16 = 36
    static let keypadEnter: UInt16 = 76
    static let letterR: UInt16 = 15
    static let letterC: UInt16 = 8
    static let letterL: UInt16 = 37
    static let leftArrow: UInt16 = 123
    static let rightArrow: UInt16 = 124
    static let delete: UInt16 = 51
    static let forwardDelete: UInt16 = 117
    /// ⌥⌘S shows the one-line subtitle, ⌥⌘I the full transcript (Practice menu).
    static let subtitlesKey: KeyEquivalent = "s"
    static let transcriptKey: KeyEquivalent = "i"
    static let optionCommandMenuCharacters: Set<String> = ["s", "i"]
}

struct ShortcutKeystroke: Equatable, Sendable {
    var keyCode: UInt16
    var characters: String = ""
    var command = false
    var shift = false
    var hasOtherModifiers = false
    /// Set with `hasOtherModifiers` when ⌥ (and not ⌃) is held, for the ⌥⌘ menu shortcuts.
    var optionOnly = false
}

enum PracticeShortcutResolver {
    /// The action for a key press, or nil to let AppKit handle it (text fields, menus, alerts).
    static func action(
        for keystroke: ShortcutKeystroke,
        textInputFocused: Bool
    ) -> PracticeShortcutAction? {
        if keystroke.hasOtherModifiers {
            return nil
        }
        if keystroke.command {
            guard !keystroke.shift, let action = commandAction(for: keystroke) else {
                return nil
            }
            // ⌘⌫ in a text field deletes to the start of the line, not a take.
            return action == .deleteTake && textInputFocused ? nil : action
        }
        if keystroke.shift || textInputFocused {
            return nil
        }
        return plainKeyAction(for: keystroke.keyCode)
    }

    /// ⌘O opens audio; ⌘⌫ moves the selected take to the Trash (like Finder).
    private static func commandAction(for keystroke: ShortcutKeystroke) -> PracticeShortcutAction? {
        if keystroke.keyCode == PracticeShortcutKeys.delete || keystroke.keyCode == PracticeShortcutKeys.forwardDelete {
            return .deleteTake
        }
        return keystroke.characters == "o" ? .openAudio : nil
    }

    private static func plainKeyAction(for keyCode: UInt16) -> PracticeShortcutAction? {
        switch keyCode {
        case PracticeShortcutKeys.space:
            .togglePlayback
        case PracticeShortcutKeys.letterR:
            .toggleRecording
        case PracticeShortcutKeys.letterC:
            .compare
        case PracticeShortcutKeys.returnKey, PracticeShortcutKeys.keypadEnter:
            .replaySentence
        case PracticeShortcutKeys.letterL:
            .toggleLoop
        case PracticeShortcutKeys.leftArrow:
            .jumpBackward
        case PracticeShortcutKeys.rightArrow:
            .jumpForward
        default:
            nil
        }
    }
}

enum PracticeShortcutGate {
    /// Sheets, alerts and popovers keep their own keys (Return presses the default button).
    @MainActor
    static func isModalUIActive(in window: NSWindow?) -> Bool {
        guard let window else {
            return false
        }
        return window.attachedSheet != nil || window.isSheet || window is NSPanel
    }

    /// Every practice window installs a monitor; only the one in the key window that the key
    /// was typed in acts, so a second window never plays or records.
    @MainActor
    static func monitorOwnsEvent(in eventWindow: NSWindow?, host: NSWindow?) -> Bool {
        guard let host, eventWindow === host else {
            return false
        }
        return host.isKeyWindow
    }

    /// True while the user types in a text field (renaming, search).
    @MainActor
    static func isTextInputFocused(in window: NSWindow?) -> Bool {
        guard let responder = window?.firstResponder else {
            return false
        }
        if let textView = responder as? NSTextView, textView.isEditable {
            return true
        }
        if let field = responder as? NSTextField, field.isEditable {
            return true
        }
        return false
    }

    /// A key the Practice menu also lists that must not act while typing: the single keys
    /// (Space, R, C, Return, L, arrows), ⌘⌫ (delete to the start of the line) and the ⌥⌘S / ⌥⌘I
    /// subtitle toggles.
    static func isMenuSingleKey(_ keystroke: ShortcutKeystroke) -> Bool {
        if keystroke.command, keystroke.optionOnly, !keystroke.shift {
            return PracticeShortcutKeys.optionCommandMenuCharacters.contains(keystroke.characters)
        }
        let action = PracticeShortcutResolver.action(for: keystroke, textInputFocused: false)
        guard keystroke.command else {
            return action != nil
        }
        return action == .deleteTake
    }
}

struct PracticeKeyboardShortcutsModifier: ViewModifier {
    let isEnabled: Bool
    let handler: @MainActor (PracticeShortcutAction) -> Void

    func body(content: Content) -> some View {
        content
            .background(
                PracticeKeyMonitor(isEnabled: isEnabled, handler: handler)
                    .frame(width: 0, height: 0)
            )
    }
}

extension View {
    func practiceKeyboardShortcuts(
        isEnabled: Bool = true,
        handler: @escaping @MainActor (PracticeShortcutAction) -> Void
    ) -> some View {
        modifier(PracticeKeyboardShortcutsModifier(isEnabled: isEnabled, handler: handler))
    }
}

private struct PracticeKeyMonitor: NSViewRepresentable {
    let isEnabled: Bool
    let handler: @MainActor (PracticeShortcutAction) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        context.coordinator.view = view
        context.coordinator.install()
        return view
    }

    func updateNSView(_: NSView, context: Context) {
        context.coordinator.isEnabled = isEnabled
        context.coordinator.handler = handler
    }

    func dismantleNSView(_: NSView, coordinator: Coordinator) {
        coordinator.remove()
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(isEnabled: isEnabled, handler: handler)
    }

    final class Coordinator: @unchecked Sendable {
        var isEnabled: Bool
        var handler: @MainActor (PracticeShortcutAction) -> Void
        weak var view: NSView?
        private var monitor: Any?

        init(
            isEnabled: Bool,
            handler: @escaping @MainActor (PracticeShortcutAction) -> Void
        ) {
            self.isEnabled = isEnabled
            self.handler = handler
        }

        func install() {
            guard monitor == nil else {
                return
            }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self, isEnabled else {
                    return event
                }
                nonisolated(unsafe) let pressed = event
                let consumed = MainActor.assumeIsolated {
                    self.handle(pressed)
                }
                return consumed ? nil : event
            }
        }

        /// True when the key was handled here (or delivered straight to a text field).
        @MainActor
        private func handle(_ event: NSEvent) -> Bool {
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            let keystroke = ShortcutKeystroke(
                keyCode: event.keyCode,
                characters: event.charactersIgnoringModifiers?.lowercased() ?? "",
                command: flags.contains(.command),
                shift: flags.contains(.shift),
                hasOtherModifiers: flags.contains(.option) || flags.contains(.control),
                optionOnly: flags.contains(.option) && !flags.contains(.control)
            )
            let window = event.window ?? NSApp.keyWindow
            let textFocused = PracticeShortcutGate.isTextInputFocused(in: window)
            if textFocused, let window, PracticeShortcutGate.isMenuSingleKey(keystroke) {
                // The menu bar lists these single keys; hand the key straight to the field so the
                // menu's key equivalent cannot swallow typed letters, spaces or Return. This also
                // covers text fields in sheets and other windows.
                window.sendEvent(event)
                return true
            }
            guard PracticeShortcutGate.monitorOwnsEvent(in: window, host: view?.window) else {
                return false
            }
            if PracticeShortcutGate.isModalUIActive(in: window) {
                return false
            }
            guard let action = PracticeShortcutResolver.action(for: keystroke, textInputFocused: textFocused) else {
                return false
            }
            handler(action)
            return true
        }

        func remove() {
            if let monitor {
                NSEvent.removeMonitor(monitor)
            }
            monitor = nil
        }
    }
}
