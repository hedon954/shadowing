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
    private var practiceShortcutHandler: ((PracticeShortcutAction) -> Void)?
    private var transitionTask: Task<Void, Never>?

    lazy var filesViewModel = FilesViewModel(
        chooser: dependencies.fileChooser,
        sessionPreparer: dependencies.sessionPreparer,
        projects: dependencies.projects
    ) { [weak self] prepared in
        self?.openPrepared(prepared)
    }

    lazy var recordingsViewModel = RecordingsViewModel(
        projects: dependencies.projects,
        takes: dependencies.takes,
        sessionPreparer: dependencies.sessionPreparer,
        fileChooser: dependencies.fileChooser
    ) { [weak self] prepared in
        self?.openPrepared(prepared)
    }

    lazy var settingsViewModel = SettingsViewModel(
        store: dependencies.settings,
        inputDevicesProvider: dependencies.inputDevices,
        storageDirectory: dependencies.recordingsStorageURL
    )

    init(dependencies: AppDependencies) {
        self.dependencies = dependencies
    }

    func registerPracticeCloser(_ closer: (@MainActor () async -> Void)?) {
        activePracticeCloser = closer
    }

    func registerPracticeShortcutHandler(
        _ handler: ((PracticeShortcutAction) -> Void)?
    ) {
        practiceShortcutHandler = handler
    }

    func handleShortcut(_ action: PracticeShortcutAction) {
        if action == .openAudio {
            openAudioChooser()
            return
        }
        practiceShortcutHandler?(action)
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

    func openAudioChooser() {
        if preparedPractice != nil {
            showFiles()
        }
        filesViewModel.chooseFile()
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
        .practiceKeyboardShortcuts(isEnabled: true) { action in
            navigation.handleShortcut(action)
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
            RecordingsView(viewModel: navigation.recordingsViewModel)
        case .settings:
            SettingsView(viewModel: navigation.settingsViewModel)
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
                navigation.registerPracticeShortcutHandler { [weak viewModel] action in
                    guard let viewModel else {
                        return
                    }
                    handleShortcut(action, viewModel: viewModel)
                }
                navigation.practiceControlsLocked = viewModel.controlsLocked
            }
            .onChange(of: viewModel.controlsLocked) { _, locked in
                navigation.practiceControlsLocked = locked
            }
            .onDisappear {
                navigation.registerPracticeCloser(nil)
                navigation.registerPracticeShortcutHandler(nil)
                navigation.practiceControlsLocked = false
            }
    }

    private func handleShortcut(
        _ action: PracticeShortcutAction,
        viewModel: PracticeViewModel
    ) {
        switch action {
        case .togglePlayback:
            viewModel.togglePlayback()
        case .toggleRecording:
            toggleRecording(viewModel)
        case .toggleLoop:
            toggleLoop(viewModel)
        case .jumpBackward:
            viewModel.jump(by: -5)
        case .jumpForward:
            viewModel.jump(by: 5)
        case .openAudio:
            navigation.openAudioChooser()
        case let .comparisonMode(mode):
            setComparisonMode(mode, viewModel: viewModel)
        case .rerecord:
            viewModel.rerecord()
        case .deleteTake:
            viewModel.requestDeleteTake()
        }
    }

    private func toggleRecording(_ viewModel: PracticeViewModel) {
        if viewModel.controlsLocked {
            viewModel.stopRecording()
            return
        }
        guard !viewModel.isComparing else {
            return
        }
        viewModel.startRecording()
    }

    private func toggleLoop(_ viewModel: PracticeViewModel) {
        guard viewModel.canToggleLoop else {
            return
        }
        viewModel.setLoopEnabled(!viewModel.loopEnabled)
    }

    private func setComparisonMode(
        _ mode: ComparisonMode,
        viewModel: PracticeViewModel
    ) {
        guard viewModel.isComparing else {
            return
        }
        viewModel.setComparisonMode(mode)
    }
}
