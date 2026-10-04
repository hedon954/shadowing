@testable import Shadowing
import SwiftUI
import XCTest

@MainActor
final class LibrarySnapshotTests: XCTestCase {
    func testEmptyLibrary() async throws {
        _ = try SnapshotSupport.outputDirectory()
        let library = try await SnapshotFixtures.library(empty: true)
        let navigation = try SnapshotFixtures.navigation(testCase: self, library: library, openFirst: false)
        try await SnapshotSupport.render(ContentView(navigation: navigation), name: "empty")
    }

    func testLibraryWithoutSelection() async throws {
        _ = try SnapshotSupport.outputDirectory()
        let library = try await SnapshotFixtures.library()
        let navigation = try SnapshotFixtures.navigation(testCase: self, library: library, openFirst: false)
        try await SnapshotSupport.render(ContentView(navigation: navigation), name: "library")
    }

    func testPracticeOpen() async throws {
        _ = try SnapshotSupport.outputDirectory()
        let library = try await SnapshotFixtures.library()
        let navigation = try SnapshotFixtures.navigation(testCase: self, library: library, openFirst: true)
        try await SnapshotSupport.render(ContentView(navigation: navigation), name: "practice")
    }
}
