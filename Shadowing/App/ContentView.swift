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
    private var activePracticeCloser: (@MainActor () async -> Void)?
    private var transitionTask: Task<Void, Never>?

    lazy var filesViewModel = FilesViewModel(
        chooser: dependencies.fileChooser,
        sessionPreparer: dependencies.sessionPreparer,
        projects: dependencies.projects
    ) { [weak self] prepared in
        self?.openPrepared(prepared)
    }

    init(dependencies: AppDependencies) {
        self.dependencies = dependencies
    }

    func registerPracticeCloser(_ closer: (@MainActor () async -> Void)?) {
        activePracticeCloser = closer
    }

    func openPrepared(_ prepared: PreparedPractice) {
        transitionTask?.cancel()
        transitionTask = Task { [weak self] in
            guard let self else {
                return
            }
            await activePracticeCloser?()
            guard !Task.isCancelled else {
                return
            }
            selectedSection = .files
            preparedPractice = prepared
            practiceControlsLocked = false
        }
    }

    func showFiles() {
        transitionTask?.cancel()
        transitionTask = Task { [weak self] in
            guard let self else {
                return
            }
            await activePracticeCloser?()
            guard !Task.isCancelled else {
                return
            }
            preparedPractice = nil
            selectedSection = .files
            practiceControlsLocked = false
        }
    }

    func selectSection(_ section: SidebarSection) {
        guard section != selectedSection else {
            return
        }
        if section == .files {
            selectedSection = .files
            return
        }
        transitionTask?.cancel()
        transitionTask = Task { [weak self] in
            guard let self else {
                return
            }
            await activePracticeCloser?()
            guard !Task.isCancelled else {
                return
            }
            preparedPractice = nil
            selectedSection = section
            practiceControlsLocked = false
        }
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
            List(selection: sectionSelection) {
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
    }

    private var sectionSelection: Binding<SidebarSection?> {
        Binding(
            get: { navigation.selectedSection },
            set: { newValue in
                guard let newValue else {
                    return
                }
                navigation.selectSection(newValue)
            }
        )
    }

    @ViewBuilder
    private var detail: some View {
        switch navigation.selectedSection {
        case .files:
            if let prepared = navigation.preparedPractice {
                PracticeScene(
                    prepared: prepared,
                    dependencies: navigation.dependencies,
                    navigation: navigation
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
    @ObservedObject var navigation: AppNavigationModel

    init(
        prepared: PreparedPractice,
        dependencies: AppDependencies,
        navigation: AppNavigationModel
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
        self.navigation = navigation
    }

    var body: some View {
        PracticeView(viewModel: viewModel, onBack: navigation.showFiles)
            .onAppear {
                navigation.registerPracticeCloser { [weak viewModel] in
                    await viewModel?.close()
                }
                navigation.practiceControlsLocked = viewModel.controlsLocked
            }
            .onChange(of: viewModel.controlsLocked) { _, locked in
                navigation.practiceControlsLocked = locked
            }
            .onDisappear {
                navigation.registerPracticeCloser(nil)
                navigation.practiceControlsLocked = false
            }
    }
}
