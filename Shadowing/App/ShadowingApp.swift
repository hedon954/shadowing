import SwiftUI

@main
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
        .defaultSize(width: 1080, height: 720)
    }
}
