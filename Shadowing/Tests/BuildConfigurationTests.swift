import Foundation
@testable import Shadowing
import XCTest

/// The test host is the Debug build, which must never share an identity or data with the installed app.
final class BuildConfigurationTests: XCTestCase {
    func testDebugBuildHasItsOwnBundleIdentifier() {
        XCTAssertEqual(Bundle.main.bundleIdentifier, "com.hedon.shadowing.debug")
    }

    func testDebugBuildKeepsItsDataInShadowingDebug() {
        let folder = AppLaunchEnvironment.dataFolderName(infoDictionary: Bundle.main.infoDictionary)
        XCTAssertEqual(folder, "Shadowing-Debug")
    }

    func testDataFolderNameFallsBackToTheReleaseFolder() {
        let key = AppLaunchEnvironment.dataFolderNameKey
        XCTAssertEqual(AppLaunchEnvironment.dataFolderName(infoDictionary: [key: "Shadowing"]), "Shadowing")
        for invalid: Any in ["", "../Shadowing", "$(SHADOWING_DATA_FOLDER_NAME)", "..", 42] {
            XCTAssertEqual(AppLaunchEnvironment.dataFolderName(infoDictionary: [key: invalid]), "Shadowing")
        }
        XCTAssertEqual(AppLaunchEnvironment.dataFolderName(infoDictionary: nil), "Shadowing")
    }
}
