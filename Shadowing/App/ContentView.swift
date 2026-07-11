import SwiftUI

enum SidebarSection: String, CaseIterable, Identifiable {
    case files = "Files"
    case recordings = "Recordings"
    case settings = "Settings"

    var id: Self {
        self
    }

    var systemImage: String {
        switch self {
        case .files:
            "folder"
        case .recordings:
            "mic"
        case .settings:
            "gearshape"
        }
    }
}

@MainActor
final class AppNavigationModel: ObservableObject {
    @Published var selectedSection: SidebarSection = .files
    @Published var preparedPractice: PreparedPractice?
    @Published var practiceControlsLocked = false

    let dependencies: AppDependencies

    lazy var filesViewModel = FilesViewModel(
        chooser: dependencies.fileChooser,
        sessionPreparer: dependencies.sessionPreparer,
        projects: dependencies.projects
    ) { [weak self] prepared in
        self?.selectedSection = .files
        self?.preparedPractice = prepared
    }

    init(dependencies: AppDependencies) {
        self.dependencies = dependencies
    }

    func showFiles() {
        preparedPractice = nil
        selectedSection = .files
    }
}

struct ContentView: View {
    @StateObject private var navigation: AppNavigationModel

    init(dependencies: AppDependencies) {
        _navigation = StateObject(
            wrappedValue: AppNavigationModel(dependencies: dependencies)
        )
    }

    var body: some View {
        NavigationSplitView {
            List(selection: $navigation.selectedSection) {
                ForEach(SidebarSection.allCases) { section in
                    Label(section.rawValue, systemImage: section.systemImage)
                        .tag(section)
                        .accessibilityLabel(section.rawValue)
                }
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 200, max: 240)
            .disabled(navigation.practiceControlsLocked)
        } detail: {
            detail
        }
        .onChange(of: navigation.selectedSection) { _, section in
            if section != .files {
                navigation.preparedPractice = nil
            }
        }
    }

    @ViewBuilder
    private var detail: some View {
        switch navigation.selectedSection {
        case .files:
            if let prepared = navigation.preparedPractice {
                PracticeScene(
                    prepared: prepared,
                    dependencies: navigation.dependencies,
                    onBack: navigation.showFiles,
                    onLockChanged: { locked in
                        navigation.practiceControlsLocked = locked
                    }
                )
                .id(prepared.project.id)
            } else {
                FilesView(viewModel: navigation.filesViewModel)
            }
        case .recordings:
            ContentUnavailableView(
                "No Recordings Yet",
                systemImage: "mic",
                description: Text("Your completed practice takes will appear here.")
            )
        case .settings:
            ContentUnavailableView(
                "Settings Coming Later",
                systemImage: "gearshape",
                description: Text("Playback settings will be added in a later milestone.")
            )
        }
    }
}

private struct PracticeScene: View {
    @StateObject private var viewModel: PracticeViewModel
    let onBack: () -> Void
    let onLockChanged: (Bool) -> Void

    init(
        prepared: PreparedPractice,
        dependencies: AppDependencies,
        onBack: @escaping () -> Void,
        onLockChanged: @escaping (Bool) -> Void
    ) {
        _viewModel = StateObject(
            wrappedValue: PracticeViewModel(
                prepared: prepared,
                audioClient: dependencies.audioClient,
                projects: dependencies.projects,
                sessionPreparer: dependencies.sessionPreparer,
                recordingDependencies: dependencies.recording
            )
        )
        self.onBack = onBack
        self.onLockChanged = onLockChanged
    }

    var body: some View {
        PracticeView(viewModel: viewModel, onBack: onBack)
            .onAppear {
                onLockChanged(viewModel.controlsLocked)
            }
            .onChange(of: viewModel.controlsLocked) { _, locked in
                onLockChanged(locked)
            }
            .onDisappear {
                onLockChanged(false)
            }
    }
}
