import AppKit
@testable import Shadowing
import SwiftUI
import XCTest

/// Sidebar + practice + transcript inspector must fit the window, down to the minimum size.
/// The split view adds the floating sidebar's width to the practice column's minimum, so a wide
/// minimum there used to push the whole split past both window edges and clip the inspector text.
@MainActor
final class PracticeWindowFitTests: XCTestCase {
    func testSplitViewFitsTheWindowWithTheInspectorOpen() async throws {
        for width in [CGFloat(900), 1024, 1180] {
            let split = try await splitFrame(windowSize: CGSize(width: width, height: 590))
            XCTAssertGreaterThanOrEqual(split.minX, -0.5, "Split starts left of a \(width)pt window")
            XCTAssertLessThanOrEqual(split.maxX, width + 0.5, "Split ends right of a \(width)pt window")
        }
    }

    /// Frame of the outermost split view in window content coordinates, after layout settles.
    private func splitFrame(windowSize: CGSize) async throws -> CGRect {
        let library = try await SnapshotFixtures.library()
        let navigation = try SnapshotFixtures.navigation(testCase: self, library: library, openFirst: true)
        let store = try XCTUnwrap(UserDefaults(suiteName: "PracticeWindowFitTests-\(UUID().uuidString)"))
        store.set(true, forKey: SubtitlePreferences.transcriptKey)
        let view = ContentView(navigation: navigation)
            .defaultAppStorage(store)
            .environment(\.prefersOpaqueChrome, true)
        let window = NSWindow(
            contentRect: CGRect(origin: CGPoint(x: -30000, y: -30000), size: windowSize),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentViewController = NSHostingController(rootView: view)
        window.setContentSize(windowSize)
        window.orderFrontRegardless()
        defer { window.close() }
        _ = await PracticeSnapshotTests.waitForPractice(navigation)
        try await Task.sleep(for: .milliseconds(600))
        let content = try XCTUnwrap(window.contentView)
        content.layoutSubtreeIfNeeded()
        let split = try XCTUnwrap(Self.firstSplitView(in: content), "No split view in the window")
        return split.convert(split.bounds, to: content)
    }

    private static func firstSplitView(in view: NSView) -> NSSplitView? {
        if let split = view as? NSSplitView {
            return split
        }
        for subview in view.subviews {
            if let split = firstSplitView(in: subview) {
                return split
            }
        }
        return nil
    }
}
