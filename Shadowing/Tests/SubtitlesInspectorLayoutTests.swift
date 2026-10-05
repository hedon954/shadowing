import AppKit
@testable import Shadowing
import SwiftUI
import XCTest

/// The subtitles inspector must lay out within its column. A long subtitle file name once made
/// the content wider than the column, so the inspector centred it and clipped every line on
/// both sides. Drawn in a real window with `cacheDisplay`; no screen capture.
@MainActor
final class SubtitlesInspectorLayoutTests: XCTestCase {
    /// `inspectorColumnWidth(min:ideal:max:)` in `PracticeView`.
    private let columnWidths: [CGFloat] = [260, 300, 360, 420]
    /// Text sits at least this far from the column edges (the inspector uses 16pt padding).
    private let minimumInset: CGFloat = 10

    func testInspectorFitsEveryColumnWidthWithLongSourceName() {
        let practice = makePractice()
        for width in columnWidths {
            let controller = NSHostingController(
                rootView: SubtitlesInspector(viewModel: practice, subtitles: practice.subtitles)
            )
            let fitting = controller.sizeThatFits(in: CGSize(width: width, height: 590))
            XCTAssertLessThanOrEqual(fitting.width, width + 0.5, "Inspector is wider than a \(width)pt column")
        }
    }

    func testInspectorTextStaysInsideColumnInRealWindow() async throws {
        let practice = makePractice()
        for width in columnWidths {
            let ink = try await inkColumns(practice: practice, width: width)
            XCTAssertGreaterThan(ink.rows, 20, "Expected transcript text at \(width)pt")
            XCTAssertGreaterThanOrEqual(
                ink.leftmost, minimumInset,
                "Text starts \(ink.leftmost)pt from the left edge of a \(width)pt inspector"
            )
            XCTAssertLessThanOrEqual(
                ink.rightmost, width - minimumInset,
                "Text ends \(width - ink.rightmost)pt from the right edge of a \(width)pt inspector"
            )
        }
    }

    // MARK: - Rendering

    private func makePractice() -> PracticeViewModel {
        let prepared = M7TestSupport.makePreparedPractice(playhead: 0)
        let practice = PracticeViewModel(
            prepared: prepared,
            audioClient: PracticeAudioClientSpy(),
            projects: InMemoryProjectRepository(storage: InMemoryPersistence()),
            sessionPreparer: FixedSessionPreparer(prepared: prepared)
        )
        SnapshotFixtures.showLongTimedSubtitles(in: practice)
        return practice
    }

    private struct Ink {
        var rows = 0
        var leftmost = CGFloat.infinity
        var rightmost = -CGFloat.infinity
    }

    /// Horizontal extent of everything drawn in the inspector, in points. Rows that are almost
    /// entirely ink (dividers) and the scroller strip on the right are ignored.
    private func inkColumns(practice: PracticeViewModel, width: CGFloat) async throws -> Ink {
        let size = CGSize(width: width, height: 560)
        let view = SubtitlesInspector(viewModel: practice, subtitles: practice.subtitles)
            .frame(width: size.width, height: size.height)
            .background(Color(nsColor: .windowBackgroundColor))
            .environment(\.locale, Locale(identifier: "zh-Hans"))
        let hosting = NSHostingView(rootView: view)
        hosting.frame = CGRect(origin: .zero, size: size)
        let window = NSWindow(
            contentRect: CGRect(origin: CGPoint(x: -20000, y: -20000), size: size),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .aqua)
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
        return try Self.ink(in: XCTUnwrap(rep.cgImage), pointWidth: width)
    }

    private static func ink(in image: CGImage, pointWidth: CGFloat) throws -> Ink {
        let width = image.width
        let height = image.height
        let scale = CGFloat(width) / pointWidth
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
        let background = luminance(width / 2, height - 1)
        // An overlay scroller may draw in the rightmost few points; text never belongs there.
        let scrollerStart = width - Int(6 * scale)
        var result = Ink()
        for row in 0 ..< height {
            var inked: [Int] = []
            for column in 0 ..< scrollerStart where abs(luminance(column, row) - background) > 0.25 {
                inked.append(column)
            }
            guard let first = inked.first, let last = inked.last,
                  inked.count < scrollerStart * 9 / 10
            else {
                continue
            }
            result.rows += 1
            result.leftmost = min(result.leftmost, CGFloat(first) / scale)
            result.rightmost = max(result.rightmost, CGFloat(last + 1) / scale)
        }
        return result
    }
}
