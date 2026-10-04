@testable import Shadowing
import SwiftUI
import XCTest

@MainActor
final class SettingsWindowTests: XCTestCase {
    func testSettingsLockWhilePracticeIsRecording() throws {
        let navigation = try AppNavigationModel(
            dependencies: NavigationTestSupport.makeDependencies(testCase: self)
        )
        XCTAssertFalse(navigation.settingsViewModel.isLocked)

        navigation.practiceControlsLocked = true
        XCTAssertTrue(navigation.settingsViewModel.isLocked)

        navigation.practiceControlsLocked = false
        XCTAssertFalse(navigation.settingsViewModel.isLocked)
    }

    func testWindowsShareTheSettingsModelTheyAreGiven() throws {
        let dependencies = try NavigationTestSupport.makeDependencies(testCase: self)
        let shared = AppNavigationModel.makeSettingsViewModel(dependencies: dependencies)
        let navigation = AppNavigationModel(dependencies: dependencies, settingsViewModel: shared)
        XCTAssertTrue(navigation.settingsViewModel === shared)
    }

    func testInputLevelMeterLightsSegmentsInProportion() {
        XCTAssertEqual(InputLevelMeter.litSegments(for: 0), 0)
        XCTAssertEqual(InputLevelMeter.litSegments(for: 0.55), 11)
        XCTAssertEqual(InputLevelMeter.litSegments(for: 1), InputLevelMeter.segmentCount)
        XCTAssertEqual(InputLevelMeter.litSegments(for: 3), InputLevelMeter.segmentCount)
        XCTAssertEqual(InputLevelMeter.litSegments(for: -1), 0)
        XCTAssertEqual(InputLevelMeter.litSegments(for: .nan), 0)
    }

    func testSettingsSnapshots() async throws {
        _ = try SnapshotSupport.outputDirectory()
        let dependencies = try NavigationTestSupport.makeDependencies(testCase: self)
        let settings = AppNavigationModel.makeSettingsViewModel(dependencies: dependencies)
        let size = CGSize(width: 460, height: 260)
        try await SnapshotSupport.render(
            SettingsView(viewModel: settings), name: "settings", size: size,
            toolbarStyle: .preference
        )
        try await SnapshotSupport.render(
            SettingsView(viewModel: settings, initialTab: .recording),
            name: "settings-recording",
            size: size,
            toolbarStyle: .preference
        )
    }
}
