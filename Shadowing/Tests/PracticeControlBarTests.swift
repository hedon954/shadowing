import AppKit
@testable import Shadowing
import SwiftUI
import XCTest

/// v6 floating control bar: 60 pt capsule that fits the practice column at every width.
@MainActor
final class PracticeControlBarTests: XCTestCase {
    private func makePractice() -> PracticeViewModel {
        let prepared = M7TestSupport.makePreparedPractice(playhead: 72)
        return PracticeViewModel(
            prepared: prepared,
            audioClient: PracticeAudioClientSpy(),
            projects: InMemoryProjectRepository(storage: InMemoryPersistence()),
            sessionPreparer: FixedSessionPreparer(prepared: prepared)
        )
    }

    func testBarIsSixtyPointsTallAndFitsNarrowAndWideColumns() {
        let practice = makePractice()
        // Practice column with the inspector open at the minimum window, up to a wide window.
        for width in [CGFloat(420), 520, 640, 800, 1000] {
            let available = width - PracticeControlBar.inset * 2
            let controller = NSHostingController(rootView: PracticeControlBar(viewModel: practice))
            let fitting = controller.sizeThatFits(in: CGSize(width: available, height: 200))
            XCTAssertEqual(fitting.height, PracticeControlBar.height, accuracy: 0.5, "at \(width)pt")
            XCTAssertLessThanOrEqual(fitting.width, available + 0.5, "Bar overflows a \(width)pt column")
        }
    }

    func testBarDrawsRecordDotOnTheRightInRealWindow() throws {
        let practice = makePractice()
        let size = CGSize(width: 760, height: 84)
        let view = PracticeControlBar(viewModel: practice)
            .padding(PracticeControlBar.inset)
            .frame(width: size.width, height: size.height)
            .background(Color.white)
            .environment(\.prefersOpaqueChrome, true)
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
        defer { window.close() }
        hosting.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        let bitmap = try XCTUnwrap(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)

        var redColumns: [Int] = []
        for column in 0 ..< bitmap.pixelsWide {
            for row in 0 ..< bitmap.pixelsHigh {
                guard let color = bitmap.colorAt(x: column, y: row)?.usingColorSpace(.sRGB) else {
                    continue
                }
                if color.redComponent > 0.85, color.greenComponent < 0.4, color.blueComponent < 0.4 {
                    redColumns.append(column)
                    break
                }
            }
        }
        let scale = CGFloat(bitmap.pixelsWide) / size.width
        let span = (CGFloat(redColumns.max() ?? 0) - CGFloat(redColumns.min() ?? 0)) / scale
        XCTAssertEqual(span, 28, accuracy: 3, "Record dot should be a 28 pt red circle")
        XCTAssertGreaterThan(CGFloat(redColumns.min() ?? 0) / scale, size.width * 0.8, "Record sits at the right end")
    }
}
