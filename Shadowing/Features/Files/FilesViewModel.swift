import Combine
import Foundation

enum FileRecoveryAction: Equatable, Sendable {
    case chooseAnother
    case relocate(UUID)
    case reloadRecents
}

struct FileLoadFailure: Equatable, Identifiable, Sendable {
    let id = UUID()
    let message: String
    let suggestion: String
    let action: FileRecoveryAction

    var recoveryTitle: String {
        switch action {
        case .chooseAnother:
            "Choose Another File"
        case .relocate:
            "Locate File"
        case .reloadRecents:
            "Try Again"
        }
    }

    static func == (lhs: FileLoadFailure, rhs: FileLoadFailure) -> Bool {
        lhs.message == rhs.message &&
            lhs.suggestion == rhs.suggestion &&
            lhs.action == rhs.action
    }
}

enum FilesLoadState: Equatable, Sendable {
    case idle
    case loading(String)
    case failed(FileLoadFailure)

    var failure: FileLoadFailure? {
        guard case let .failed(failure) = self else {
            return nil
        }
        return failure
    }
}

@MainActor
final class FilesViewModel: ObservableObject {
    @Published private(set) var state: FilesLoadState = .idle
    @Published private(set) var recentProjects: [AudioProject] = []

    private let chooser: any AudioFileChoosing
    private let sessionPreparer: any PracticeSessionPreparing
    private let projects: any ProjectRepository
    private let onPracticeReady: @MainActor (PreparedPractice) -> Void
    private var loadTask: Task<Void, Never>?

    init(
        chooser: any AudioFileChoosing,
        sessionPreparer: any PracticeSessionPreparing,
        projects: any ProjectRepository,
        onPracticeReady: @escaping @MainActor (PreparedPractice) -> Void
    ) {
        self.chooser = chooser
        self.sessionPreparer = sessionPreparer
        self.projects = projects
        self.onPracticeReady = onPracticeReady
    }

    deinit {
        loadTask?.cancel()
    }

    func loadRecentProjects() async {
        do {
            recentProjects = try await projects.recentProjects(limit: 8)
        } catch is CancellationError {
            return
        } catch {
            state = .failed(
                FileLoadFailure(
                    message: "Recent files could not be loaded.",
                    suggestion: "Try loading the list again.",
                    action: .reloadRecents
                )
            )
        }
    }

    func chooseFile() {
        loadTask?.cancel()
        loadTask = Task { [weak self] in
            guard let self, let url = await chooser.chooseMP3() else {
                return
            }
            await loadNewSource(url)
        }
    }

    func acceptDroppedFile(_ url: URL) {
        startLoading(name: url.lastPathComponent, recovery: .chooseAnother) { [sessionPreparer] in
            try await sessionPreparer.prepareNewSource(at: url)
        }
    }

    func openRecentProject(_ project: AudioProject) {
        startLoading(name: project.sourceDisplayName, recovery: .relocate(project.id)) { [sessionPreparer] in
            try await sessionPreparer.prepareExistingProject(id: project.id)
        }
    }

    func recover() {
        guard let failure = state.failure else {
            return
        }
        switch failure.action {
        case .chooseAnother:
            chooseFile()
        case let .relocate(projectID):
            relocate(projectID: projectID)
        case .reloadRecents:
            Task { [weak self] in
                guard let self else {
                    return
                }
                state = .idle
                await loadRecentProjects()
            }
        }
    }

    func dismissFailure() {
        state = .idle
    }

    func cancelLoading() {
        loadTask?.cancel()
        loadTask = nil
        state = .idle
    }

    private func loadNewSource(_ url: URL) async {
        state = .loading(url.lastPathComponent)
        do {
            let prepared = try await sessionPreparer.prepareNewSource(at: url)
            try Task.checkCancellation()
            state = .idle
            onPracticeReady(prepared)
            await loadRecentProjects()
        } catch is CancellationError {
            state = .idle
        } catch {
            show(error: error, recovery: .chooseAnother)
        }
    }

    private func relocate(projectID: UUID) {
        loadTask?.cancel()
        loadTask = Task { [weak self] in
            guard let self, let url = await chooser.chooseMP3() else {
                return
            }
            startLoading(name: url.lastPathComponent, recovery: .relocate(projectID)) { [sessionPreparer] in
                try await sessionPreparer.relocateProject(id: projectID, to: url)
            }
        }
    }

    private func startLoading(
        name: String,
        recovery: FileRecoveryAction,
        operation: @escaping @Sendable () async throws -> PreparedPractice
    ) {
        loadTask?.cancel()
        state = .loading(name)
        loadTask = Task { [weak self] in
            guard let self else {
                return
            }
            do {
                let prepared = try await operation()
                try Task.checkCancellation()
                state = .idle
                onPracticeReady(prepared)
                await loadRecentProjects()
            } catch is CancellationError {
                state = .idle
            } catch {
                show(error: error, recovery: recovery)
            }
        }
    }

    private func show(error: Error, recovery: FileRecoveryAction) {
        let sourceError = error as? AudioSourceError
        state = .failed(
            FileLoadFailure(
                message: sourceError?.localizedDescription ?? error.localizedDescription,
                suggestion: sourceError?.recoverySuggestion ?? "Try again or choose another MP3 file.",
                action: recovery
            )
        )
    }
}
