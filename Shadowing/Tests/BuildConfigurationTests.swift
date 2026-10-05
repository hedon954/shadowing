import Foundation
import XCTest

/// The test host is the Debug build, which must never share an identity with the installed app.
final class BuildConfigurationTests: XCTestCase {
    func testDebugBuildHasItsOwnBundleIdentifier() {
        XCTAssertEqual(Bundle.main.bundleIdentifier, "com.hedon.shadowing.debug")
    }
}
