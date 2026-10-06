import AppKit
@testable import Shadowing
import SwiftUI
import XCTest

/// Draws the timed transcript in a real window (light and dark) with `cacheDisplay` and reads
/// the pixels: only the current sentence uses the primary label color, played and upcoming
/// ones are the same lighter secondary color, and nothing draws black in dark mode. No screen
/// capture, so no permission prompt.
@MainActor
final class SubtitleTranscriptAppearanceTests: XCTestCase {
    private let cues = [
        SubtitleCue(start: 0, end: 2, text: "Already played."),
        SubtitleCue(start: 10, end: 12, text: "Playing now."),
        SubtitleCue(start: 20, end: 22, text: "Coming up next.")
    ]

    func testDarkModeOnlyTheCurrentSentenceIsPrimary() async throws {
        let bands = try await textBands(dark: true)
        XCTAssertEqual(bands.count, 3, "One line per sentence")
        let played = bands[0].brightest, current = bands[1].brightest, upcoming = bands[2].brightest
        XCTAssertGreaterThan(current, 0.75, "The current sentence uses the primary label color")
        XCTAssertGreaterThan(played, 0.35, "Other sentences must not draw black")
        XCTAssertLessThan(played, current - 0.1, "Played sentences use the secondary label color")
        XCTAssertLessThan(upcoming, current - 0.1, "Upcoming sentences use the secondary label color")
        XCTAssertEqual(played, upcoming, accuracy: 0.05)
    }

    func testLightModeOnlyTheCurrentSentenceIsPrimary() async throws {
        let bands = try await textBands(dark: false)
        XCTAssertEqual(bands.count, 3, "One line per sentence")
        let played = bands[0].darkest, current = bands[1].darkest, upcoming = bands[2].darkest
        XCTAssertLessThan(current, 0.3, "The current sentence uses the primary label color")
        XCTAssertGreaterThan(played, current + 0.1, "Played sentences use the secondary label color")
        XCTAssertGreaterThan(upcoming, current + 0.1, "Upcoming sentences use the secondary label color")
        XCTAssertEqual(played, upcoming, accuracy: 0.05)
        XCTAssertLessThan(played, 0.75)
    }

    // MARK: - Rendering

    private struct Band {
        var brightest: Double = 0
        var darkest: Double = 1
    }

    private func textBands(dark: Bool) async throws -> [Band] {
        let size = CGSize(width: 300, height: 220)
        let view = SubtitleTranscriptView(
            transcript: SubtitleTranscript(cues: cues),
            current: SubtitleTimeline.cueIndex(at: 11, in: cues),
            revealToken: 0,
            autoFollows: { true },
            onUserScroll: {},
            onSeek: { _ in }
        )
        .frame(width: size.width, height: size.height)
        .background(Color(nsColor: .windowBackgroundColor))
        let hosting = NSHostingView(rootView: view)
        hosting.frame = CGRect(origin: .zero, size: size)
        let window = NSWindow(
            contentRect: CGRect(origin: CGPoint(x: -20000, y: -20000), size: size),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.contentView = hosting
        window.orderFrontRegardless()
        defer {
            window.orderOut(nil)
            window.close()
        }
        try await Task.sleep(for: .milliseconds(400))
        hosting.layoutSubtreeIfNeeded()
        let rep = try XCTUnwrap(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        try savePNG(rep, dark: dark)
        return try Self.bands(in: XCTUnwrap(rep.cgImage))
    }

    /// Rows that differ from the background, grouped into lines of text, top to bottom.
    private static func bands(in image: CGImage) throws -> [Band] {
        let width = image.width
        let height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let context = try XCTUnwrap(
            CGContext(
                data: &pixels,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
        )
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        func luminance(_ column: Int, _ row: Int) -> Double {
            let offset = (row * width + column) * 4
            let red = Double(pixels[offset]), green = Double(pixels[offset + 1]), blue = Double(pixels[offset + 2])
            return (0.2126 * red + 0.7152 * green + 0.0722 * blue) / 255
        }
        let background = luminance(1, 1)
        var bands: [Band] = []
        var current: Band?
        for line in 0 ..< height {
            var row = Band()
            var hasInk = false
            for column in 0 ..< width {
                let value = luminance(column, line)
                if abs(value - background) > 0.06 {
                    hasInk = true
                    row.brightest = max(row.brightest, value)
                    row.darkest = min(row.darkest, value)
                }
            }
            if hasInk {
                var band = current ?? Band()
                band.brightest = max(band.brightest, row.brightest)
                band.darkest = min(band.darkest, row.darkest)
                current = band
            } else if let finished = current {
                bands.append(finished)
                current = nil
            }
        }
        if let current {
            bands.append(current)
        }
        return bands
    }

    private func savePNG(_ rep: NSBitmapImageRep, dark: Bool) throws {
        guard let path = ProcessInfo.processInfo.environment["SHADOWING_SNAPSHOT_DIR"], !path.isEmpty else {
            return
        }
        let name = "sub-transcript-window-\(SnapshotSupport.languageSuffix)-\(dark ? "dark" : "light").png"
        let data = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
        try data.write(to: URL(fileURLWithPath: path, isDirectory: true).appendingPathComponent(name))
    }
}
