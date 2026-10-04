import SwiftUI

/// A normal launch runs `ShadowingApp`. The XCTest host runs an app without windows, so tests
/// never create `AppDependencies`, open the database or clean up recordings.
@main
enum ShadowingMain {
    static func main() {
        if AppLaunchEnvironment.isRunningTests {
            TestHostApp.main()
        } else {
            ShadowingApp.main()
        }
    }
}

private struct TestHostApp: App {
    var body: some Scene {
        Settings {
            EmptyView()
        }
    }
}

struct ShadowingApp: App {
    private let dependencies: Result<AppDependencies, Error>

    init() {
        dependencies = Result {
            try AppDependencies.live()
        }
    }

    var body: some Scene {
        WindowGroup {
            switch dependencies {
            case let .success(dependencies):
                ContentView(dependencies: dependencies)
            case let .failure(error):
                ContentUnavailableView(
                    "Shadowing Couldn’t Start",
                    systemImage: "exclamationmark.triangle",
                    description: Text(error.localizedDescription)
                )
                .frame(minWidth: 600, minHeight: 400)
            }
        }
        .defaultSize(width: 1180, height: 720)
        .windowToolbarStyle(.unified)
    }
}
