import Foundation

/// Where Shadowing keeps its data, and whether this process is an XCTest host.
///
/// Under XCTest the data folder is a temporary directory (or `SHADOWING_TEST_DATA_DIR`), so tests
/// can never open the real `Shadowing.sqlite` or touch real recordings. The override is ignored
/// in a normal launch.
enum AppLaunchEnvironment {
    static let testDataDirectoryKey = "SHADOWING_TEST_DATA_DIR"

    static var isRunningTests: Bool {
        isRunningTests(environment: ProcessInfo.processInfo.environment)
    }

    static func isRunningTests(environment: [String: String]) -> Bool {
        environment["XCTestConfigurationFilePath"] != nil
    }

    /// `nil` means the normal Application Support location.
    static func testDataDirectory(environment: [String: String]) -> URL? {
        guard isRunningTests(environment: environment) else {
            return nil
        }
        if let override = environment[testDataDirectoryKey], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        return FileManager.default.temporaryDirectory.appendingPathComponent(
            "ShadowingTests-\(ProcessInfo.processInfo.processIdentifier)",
            isDirectory: true
        )
    }
}
