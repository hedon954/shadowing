import AppKit
@testable import Shadowing
import XCTest

/// Single-key shortcuts for the core loop, and the rule that they never fire while typing.
@MainActor
final class PracticeShortcutTests: XCTestCase {
    private func action(_ keyCode: UInt16, typing: Bool = false) -> PracticeShortcutAction? {
        PracticeShortcutResolver.action(for: ShortcutKeystroke(keyCode: keyCode), textInputFocused: typing)
    }

    func testCoreLoopKeys() {
        XCTAssertEqual(action(PracticeShortcutKeys.space), .togglePlayback)
        XCTAssertEqual(action(PracticeShortcutKeys.letterR), .toggleRecording)
        XCTAssertEqual(action(PracticeShortcutKeys.letterC), .compare)
        XCTAssertEqual(action(PracticeShortcutKeys.returnKey), .replaySentence)
        XCTAssertEqual(action(PracticeShortcutKeys.keypadEnter), .replaySentence)
        XCTAssertEqual(action(PracticeShortcutKeys.letterL), .toggleLoop)
        XCTAssertEqual(action(PracticeShortcutKeys.leftArrow), .jumpBackward)
        XCTAssertEqual(action(PracticeShortcutKeys.rightArrow), .jumpForward)
    }

    func testNoSingleKeyFiresWhileATextFieldHasFocus() {
        let keys = [
            PracticeShortcutKeys.space, PracticeShortcutKeys.letterR, PracticeShortcutKeys.letterC,
            PracticeShortcutKeys.returnKey, PracticeShortcutKeys.letterL, PracticeShortcutKeys.leftArrow,
            PracticeShortcutKeys.rightArrow
        ]
        for key in keys {
            XCTAssertNil(action(key, typing: true), "key \(key) fired while typing")
        }
        let open = ShortcutKeystroke(keyCode: 31, characters: "o", command: true)
        XCTAssertEqual(PracticeShortcutResolver.action(for: open, textInputFocused: true), .openAudio)
        // These are the keys handed straight to the text field instead of the menu bar.
        XCTAssertTrue(keys.allSatisfy { PracticeShortcutGate.isMenuSingleKey(ShortcutKeystroke(keyCode: $0)) })
        XCTAssertFalse(PracticeShortcutGate.isMenuSingleKey(open))
        XCTAssertFalse(PracticeShortcutGate.isMenuSingleKey(ShortcutKeystroke(keyCode: 0)), "A is just typing")
    }

    /// Delete is ⌘⌫ like Finder's Move to Trash; bare ⌫ does nothing, and ⌘⌫ while typing
    /// edits the text instead.
    func testDeleteTakeNeedsCommandAndNeverFiresWhileTyping() {
        let commandDelete = ShortcutKeystroke(keyCode: PracticeShortcutKeys.delete, command: true)
        XCTAssertNil(action(PracticeShortcutKeys.delete))
        XCTAssertNil(action(PracticeShortcutKeys.forwardDelete))
        XCTAssertEqual(PracticeShortcutResolver.action(for: commandDelete, textInputFocused: false), .deleteTake)
        XCTAssertNil(PracticeShortcutResolver.action(for: commandDelete, textInputFocused: true))
        XCTAssertTrue(PracticeShortcutGate.isMenuSingleKey(commandDelete), "handed to the text field, not the menu")
        XCTAssertFalse(PracticeShortcutGate.isMenuSingleKey(ShortcutKeystroke(keyCode: PracticeShortcutKeys.delete)))
    }

    func testModifiedKeysAreLeftToTheMenuBar() {
        let optionC = ShortcutKeystroke(keyCode: PracticeShortcutKeys.letterC, hasOtherModifiers: true)
        let shiftR = ShortcutKeystroke(keyCode: PracticeShortcutKeys.letterR, shift: true)
        let commandC = ShortcutKeystroke(keyCode: PracticeShortcutKeys.letterC, characters: "c", command: true)
        XCTAssertNil(PracticeShortcutResolver.action(for: optionC, textInputFocused: false))
        XCTAssertNil(PracticeShortcutResolver.action(for: shiftR, textInputFocused: false))
        XCTAssertNil(PracticeShortcutResolver.action(for: commandC, textInputFocused: false), "⌘C stays Copy")
    }

    func testGateSeesAFocusedTextFieldInARealWindow() {
        let window = NSWindow(
            contentRect: CGRect(x: -20000, y: -20000, width: 300, height: 120),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let field = NSTextField(frame: CGRect(x: 10, y: 10, width: 200, height: 24))
        let button = NSButton(frame: CGRect(x: 10, y: 50, width: 100, height: 24))
        window.contentView?.addSubview(field)
        window.contentView?.addSubview(button)

        XCTAssertTrue(window.makeFirstResponder(button))
        XCTAssertFalse(PracticeShortcutGate.isTextInputFocused(in: window))

        XCTAssertTrue(window.makeFirstResponder(field))
        XCTAssertTrue(PracticeShortcutGate.isTextInputFocused(in: window), "editing a name or search")

        field.isEditable = false
        field.isSelectable = false
        XCTAssertTrue(window.makeFirstResponder(button))
        XCTAssertFalse(PracticeShortcutGate.isTextInputFocused(in: window))
        XCTAssertFalse(PracticeShortcutGate.isModalUIActive(in: window))
    }

    func testOnlyTheMonitorOfTheWindowThatGotTheKeyActs() {
        let first = NSWindow(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: true)
        let second = NSWindow(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: true)
        first.isReleasedWhenClosed = false
        second.isReleasedWhenClosed = false
        XCTAssertFalse(PracticeShortcutGate.monitorOwnsEvent(in: first, host: second))
        XCTAssertFalse(PracticeShortcutGate.monitorOwnsEvent(in: nil, host: first))
        XCTAssertFalse(PracticeShortcutGate.monitorOwnsEvent(in: first, host: nil))
        XCTAssertFalse(first.isKeyWindow)
        XCTAssertFalse(PracticeShortcutGate.monitorOwnsEvent(in: first, host: first), "a background window")
    }

    func testSpeedStepsThroughTheSupportedRates() {
        let prepared = M7TestSupport.makePreparedPractice(playhead: 0)
        let model = PracticeViewModel(
            prepared: prepared,
            audioClient: PracticeAudioClientSpy(),
            projects: InMemoryProjectRepository(storage: InMemoryPersistence()),
            sessionPreparer: FixedSessionPreparer(prepared: prepared)
        )
        model.stepRate(faster: true)
        XCTAssertEqual(model.rate, 1.25)
        model.stepRate(faster: false)
        model.stepRate(faster: false)
        XCTAssertEqual(model.rate, 0.75)
        for _ in 0 ..< 5 {
            model.stepRate(faster: false)
        }
        XCTAssertEqual(model.rate, 0.5)
    }
}
