import AppKit
import SwiftUI

enum PracticeShortcutAction: Equatable, Sendable {
    case togglePlayback
    case toggleRecording
    case toggleLoop
    case jumpBackward
    case jumpForward
    case openAudio
    case comparisonMode(ComparisonMode)
    case rerecord
    case deleteTake
}

enum PracticeShortcutGate {
    /// Local key monitors run on the main thread; AppKit focus is read there.
    nonisolated static var isTextInputFocused: Bool {
        MainActor.assumeIsolated {
            guard let responder = NSApp.keyWindow?.firstResponder else {
                return false
            }
            if responder is NSTextView {
                return true
            }
            if let field = responder as? NSTextField, field.isEditable {
                return true
            }
            guard let view = responder as? NSView else {
                return false
            }
            guard let fieldEditor = view.window?.fieldEditor(false, for: nil) else {
                return false
            }
            return fieldEditor === responder
        }
    }
}

private struct ShortcutKeystroke: Sendable {
    let keyCode: UInt16
    let characters: String
    let command: Bool
    let shift: Bool
    let hasOtherModifiers: Bool
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
                let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
                let keystroke = ShortcutKeystroke(
                    keyCode: event.keyCode,
                    characters: event.charactersIgnoringModifiers?.lowercased() ?? "",
                    command: flags.contains(.command),
                    shift: flags.contains(.shift),
                    hasOtherModifiers: flags.contains(.option) || flags.contains(.control)
                )
                if PracticeShortcutGate.isTextInputFocused {
                    return event
                }
                guard let action = Self.action(for: keystroke) else {
                    return event
                }
                let handler = handler
                MainActor.assumeIsolated {
                    handler(action)
                }
                return nil
            }
        }

        func remove() {
            if let monitor {
                NSEvent.removeMonitor(monitor)
            }
            monitor = nil
        }

        private static func action(for keystroke: ShortcutKeystroke) -> PracticeShortcutAction? {
            if keystroke.hasOtherModifiers {
                return nil
            }
            if keystroke.command {
                return commandAction(for: keystroke)
            }
            if keystroke.shift {
                return nil
            }
            return plainKeyAction(for: keystroke.keyCode)
        }

        private static func commandAction(for keystroke: ShortcutKeystroke) -> PracticeShortcutAction? {
            if keystroke.shift, keystroke.characters == "r" {
                return .rerecord
            }
            guard !keystroke.shift else {
                return nil
            }
            switch keystroke.characters {
            case "o":
                return .openAudio
            case "1":
                return .comparisonMode(.original)
            case "2":
                return .comparisonMode(.selectedTake)
            case "3":
                return .comparisonMode(.ab)
            default:
                return nil
            }
        }

        private static func plainKeyAction(for keyCode: UInt16) -> PracticeShortcutAction? {
            switch keyCode {
            case 49:
                .togglePlayback
            case 15:
                .toggleRecording
            case 37:
                .toggleLoop
            case 123:
                .jumpBackward
            case 124:
                .jumpForward
            case 51, 117:
                .deleteTake
            default:
                nil
            }
        }
    }
}
