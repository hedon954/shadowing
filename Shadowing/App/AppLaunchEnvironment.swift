import Foundation

/// Where Shadowing keeps its data, and whether this process is an XCTest host.
///
/// Under XCTest the data folder is a temporary directory (or `SHADOWING_TEST_DATA_DIR`), so tests
/// can never open the real `Shadowing.sqlite` or touch real recordings. The override is ignored
/// in a normal launch.
enum AppLaunchEnvironment {
    static let testDataDirectoryKey = "SHADOWING_TEST_DATA_DIR"
    /// Info.plist key naming the folder under Application Support (per build configuration).
    static let dataFolderNameKey = "ShadowingDataFolderName"
    static let defaultDataFolderName = "Shadowing"

    /// `Shadowing` for Release, `Shadowing-Debug` for Debug builds, so a Debug build never opens
    /// the installed app's library. Anything missing or odd falls back to `Shadowing`.
    static func dataFolderName(infoDictionary: [String: Any]?) -> String {
        guard let name = infoDictionary?[dataFolderNameKey] as? String,
              !name.isEmpty,
              !name.contains("/"),
              !name.contains("$("),
              name != ".",
              name != ".."
        else {
            return defaultDataFolderName
        }
        return name
    }

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
