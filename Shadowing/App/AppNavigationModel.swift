import SwiftUI

@MainActor
final class AppNavigationModel: ObservableObject {
    @Published var preparedPractice: PreparedPractice?
    @Published var practiceControlsLocked = false
    @Published var isSettingsPresented = false
    /// Sidebar highlight; set on click so the row stays selected while the file loads.
    @Published var selectedProjectID: UUID?

    let dependencies: AppDependencies
    private var activePracticeCloser: (@MainActor () async -> Void)?
    private var practiceLeaveRequester: (@MainActor (@escaping @MainActor () -> Void) -> Void)?
    private var practiceShortcutHandler: ((PracticeShortcutAction) -> Void)?
    private var transitionTask: Task<Void, Never>?
    private var chooserTask: Task<Void, Never>?
    /// Restores the sidebar highlight when the user keeps recording instead of leaving.
    private var pendingLeaveCancel: (@MainActor () -> Void)?

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

    var currentProjectID: UUID? {
        preparedPractice?.project.id
    }

    /// The sidebar marks the file whose practice is recording (or about to).
    func isRecording(projectID: UUID) -> Bool {
        practiceControlsLocked && projectID == currentProjectID
    }

    func registerPracticeCloser(_ closer: (@MainActor () async -> Void)?) {
        activePracticeCloser = closer
    }

    /// The open practice decides whether leaving needs confirmation (for example while recording).
    func registerPracticeLeaveRequester(
        _ requester: (@MainActor (@escaping @MainActor () -> Void) -> Void)?
    ) {
        practiceLeaveRequester = requester
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
            selectedProjectID = prepared.project.id
            practiceControlsLocked = false
        }
    }

    /// Opens a sidebar row. The current practice is closed first: preparing a file replaces the
    /// shared audio session, so the old practice must end before the new one loads.
    func openLibraryItem(_ item: LibraryProjectItem) {
        guard item.id != currentProjectID else {
            return
        }
        let previousSelection = selectedProjectID
        selectedProjectID = item.id
        leavePractice(onCancel: { [weak self] in
            self?.selectedProjectID = previousSelection
        }, then: { [weak self] in
            self?.selectedProjectID = item.id
            self?.filesViewModel.openLibraryItem(item)
        })
    }

    func acceptDroppedFiles(_ urls: [URL]) -> Bool {
        guard let url = urls.first else {
            return false
        }
        leavePractice { [weak self] in
            self?.selectedProjectID = nil
            self?.filesViewModel.acceptDroppedFile(url)
        }
        return true
    }

    /// Picks the file first, so cancelling the panel keeps the current practice open.
    func openAudioChooser() {
        chooserTask?.cancel()
        chooserTask = Task { [weak self] in
            guard let self, let url = await dependencies.fileChooser.chooseMP3() else {
                return
            }
            _ = acceptDroppedFiles([url])
        }
    }

    private func leavePractice(
        onCancel: (@MainActor () -> Void)? = nil,
        then next: @escaping @MainActor () -> Void
    ) {
        guard preparedPractice != nil, let practiceLeaveRequester else {
            next()
            return
        }
        pendingLeaveCancel = onCancel
        practiceLeaveRequester { [weak self] in
            guard let self else {
                return
            }
            pendingLeaveCancel = nil
            isSettingsPresented = false
            preparedPractice = nil
            practiceControlsLocked = false
            next()
        }
    }

    func practiceLeaveCancelled() {
        pendingLeaveCancel?()
        pendingLeaveCancel = nil
    }
}
