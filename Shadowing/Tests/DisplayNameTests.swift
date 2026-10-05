@testable import Shadowing
import XCTest

final class DisplayNameTests: XCTestCase {
    func testDropsLeadingNumberAndExtensionAndTurnsHyphensIntoSpaces() {
        XCTAssertEqual(
            DisplayName.cleaned("01-second-hand-ecommerce-idle-asset-liquidity-conversation.mp3"),
            "Second hand ecommerce idle asset liquidity conversation"
        )
        XCTAssertEqual(DisplayName.cleaned("3. Why we procrastinate.m4a"), "Why we procrastinate")
        XCTAssertEqual(DisplayName.cleaned("12_non_standardization.mp3"), "Non standardization")
    }

    func testKeepsNamesThatAreAlreadyReadable() {
        XCTAssertEqual(DisplayName.cleaned("TED: The power of vulnerability.mp3"), "TED: The power of vulnerability")
        XCTAssertEqual(DisplayName.cleaned("iPhone tips.mp3"), "iPhone tips")
        XCTAssertEqual(DisplayName.cleaned("Speech"), "Speech")
    }

    func testNeverReturnsAnEmptyName() {
        XCTAssertEqual(DisplayName.cleaned("2024.mp3"), "2024")
        XCTAssertEqual(DisplayName.cleaned("01-.mp3"), "01")
        XCTAssertEqual(DisplayName.cleaned(".mp3"), ".mp3")
    }
}
