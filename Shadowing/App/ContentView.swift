import SwiftUI

@MainActor
final class AppNavigationModel: ObservableObject {
    @Published var preparedPractice: PreparedPractice?
    @Published var practiceControlsLocked = false
    @Published var isSettingsPresented = false

    let dependencies: AppDependencies
    private var activePracticeCloser: (@MainActor () async -> Void)?
    private var practiceShortcutHandler: ((PracticeShortcutAction) -> Void)?
    private var transitionTask: Task<Void, Never>?

    lazy var filesViewModel = FilesViewModel(
        chooser: dependencies.fileChooser,
        sessionPreparer: dependencies.sessionPreparer,
        projects: dependencies.projects,
        takes: dependencies.takes
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
            isSettingsPresented = false
            preparedPractice = prepared
            practiceControlsLocked = false
        }
    }

    func showLibrary() {
        transitionTask?.cancel()
        transitionTask = Task { [weak self] in
            guard let self else {
                return
            }
            await activePracticeCloser?()
            guard !Task.isCancelled else {
                return
            }
            isSettingsPresented = false
            preparedPractice = nil
            practiceControlsLocked = false
        }
    }

    func openAudioChooser() {
        if preparedPractice != nil {
            showLibrary()
        }
        filesViewModel.chooseFile()
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
        NavigationStack {
            detail
                .toolbar {
                    ToolbarItem(placement: .primaryAction) {
                        settingsButton
                    }
                }
        }
        .practiceKeyboardShortcuts(isEnabled: true) { action in
            navigation.handleShortcut(action)
        }
    }

    private var settingsButton: some View {
        Button {
            navigation.isSettingsPresented.toggle()
        } label: {
            Label("Settings", systemImage: "gearshape")
        }
        .popover(isPresented: $navigation.isSettingsPresented, arrowEdge: .bottom) {
            SettingsView(viewModel: navigation.settingsViewModel)
                .frame(width: 400, height: 520)
        }
        .disabled(navigation.practiceControlsLocked)
        .accessibilityLabel("Settings")
        .help("Settings")
    }

    @ViewBuilder
    private var detail: some View {
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
        PracticeView(viewModel: viewModel, onBack: navigation.showLibrary)
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
        case .deleteTake:
            viewModel.requestDeleteTake()
        }
    }

    private func toggleRecording(_ viewModel: PracticeViewModel) {
        if viewModel.controlsLocked {
            viewModel.stopRecording()
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
}
