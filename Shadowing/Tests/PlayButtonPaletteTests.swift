import AppKit
@testable import Shadowing
import SwiftUI
import XCTest

/// The play button must read as an active control in both appearances: a dark solid circle with
/// a white icon in light mode, a light circle with a dark icon in dark mode.
final class PlayButtonPaletteTests: XCTestCase {
    func testCircleIsSolidAndTheIconContrastsInLightAndDarkMode() throws {
        for scheme in [ColorScheme.light, .dark] {
            let circle = try components(PlayButtonPalette.circle(for: scheme))
            let icon = try components(PlayButtonPalette.icon(for: scheme))

            XCTAssertEqual(circle.alpha, 1, "a translucent circle looks grey and disabled")
            XCTAssertGreaterThanOrEqual(contrast(circle.luminance, icon.luminance), 7, "\(scheme)")
        }
        XCTAssertLessThan(try components(PlayButtonPalette.circle(for: .light)).luminance, 0.05)
        XCTAssertEqual(try components(PlayButtonPalette.icon(for: .light)).luminance, 1, accuracy: 0.001)
        XCTAssertGreaterThan(try components(PlayButtonPalette.circle(for: .dark)).luminance, 0.85)
    }

    private func components(_ color: Color) throws -> (luminance: CGFloat, alpha: CGFloat) {
        let resolved = try XCTUnwrap(NSColor(color).usingColorSpace(.sRGB))
        func linear(_ value: CGFloat) -> CGFloat {
            value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        let luminance = 0.2126 * linear(resolved.redComponent)
            + 0.7152 * linear(resolved.greenComponent)
            + 0.0722 * linear(resolved.blueComponent)
        return (luminance, resolved.alphaComponent)
    }

    private func contrast(_ first: CGFloat, _ second: CGFloat) -> CGFloat {
        (max(first, second) + 0.05) / (min(first, second) + 0.05)
    }
}
