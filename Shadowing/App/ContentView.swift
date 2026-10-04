import SwiftUI

struct ContentView: View {
    @StateObject private var navigation: AppNavigationModel
    @State private var isDropTargeted = false

    init(dependencies: AppDependencies, settingsViewModel: SettingsViewModel) {
        self.init(
            navigation: AppNavigationModel(
                dependencies: dependencies,
                settingsViewModel: settingsViewModel
            )
        )
    }

    /// Lets previews and snapshot tests drive navigation with fake dependencies.
    init(navigation: @autoclosure @escaping () -> AppNavigationModel) {
        _navigation = StateObject(wrappedValue: navigation())
    }

    var body: some View {
        NavigationSplitView {
            LibrarySidebar(viewModel: navigation.filesViewModel, navigation: navigation)
                .navigationSplitViewColumnWidth(min: 200, ideal: 240, max: 340)
        } detail: {
            detail
        }
        .frame(minWidth: 900, minHeight: 560)
        .dropDestination(for: URL.self) { urls, _ in
            navigation.acceptDroppedFiles(urls)
        } isTargeted: { targeted in
            isDropTargeted = targeted
        }
        .overlay {
            if isDropTargeted {
                Rectangle()
                    .strokeBorder(Color.accentColor, lineWidth: 3)
                    .background(Color.accentColor.opacity(0.06))
                    .ignoresSafeArea()
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
        .practiceKeyboardShortcuts(isEnabled: true) { action in
            navigation.handleShortcut(action)
        }
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
            LibraryDetailView(viewModel: navigation.filesViewModel, navigation: navigation)
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
                recordingDependencies: dependencies.recording,
                textFileChooser: dependencies.textFileChooser
            )
        )
        self.navigation = navigation
    }

    var body: some View {
        PracticeView(viewModel: viewModel)
            .onAppear {
                navigation.registerActivePractice(viewModel)
                navigation.registerPracticeCloser { [weak viewModel] in
                    await viewModel?.close()
                }
                navigation.registerPracticeLeaveRequester { [weak viewModel] leave in
                    guard let viewModel else {
                        leave()
                        return
                    }
                    viewModel.requestLeave(then: leave)
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
            .onChange(of: viewModel.leaveConfirmation) { previous, current in
                if previous != nil, current == nil, viewModel.leaveAfterFinalize == nil {
                    navigation.practiceLeaveCancelled()
                }
            }
            .onChange(of: viewModel.takes.count) {
                Task {
                    await navigation.filesViewModel.loadLibrary()
                }
            }
            .onDisappear {
                navigation.registerActivePractice(nil)
                navigation.registerPracticeCloser(nil)
                navigation.registerPracticeLeaveRequester(nil)
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
