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

struct LibraryProjectItem: Equatable, Identifiable, Sendable {
    var id: UUID {
        project.id
    }

    let project: AudioProject
    let takeCount: Int
    let lastRecordedAt: Date?

    /// Sort key: most recent of last open and last recording.
    var activityDate: Date {
        max(project.lastOpenedAt, lastRecordedAt ?? .distantPast)
    }
}

@MainActor
final class FilesViewModel: ObservableObject {
    @Published private(set) var state: FilesLoadState = .idle
    @Published private(set) var libraryItems: [LibraryProjectItem] = []

    private let chooser: any AudioFileChoosing
    private let sessionPreparer: any PracticeSessionPreparing
    private let projects: any ProjectRepository
    private let takes: any TakeRepository
    private let onPracticeReady: @MainActor (PreparedPractice) -> Void
    private var loadTask: Task<Void, Never>?

    init(
        chooser: any AudioFileChoosing,
        sessionPreparer: any PracticeSessionPreparing,
        projects: any ProjectRepository,
        takes: any TakeRepository,
        onPracticeReady: @escaping @MainActor (PreparedPractice) -> Void
    ) {
        self.chooser = chooser
        self.sessionPreparer = sessionPreparer
        self.projects = projects
        self.takes = takes
        self.onPracticeReady = onPracticeReady
    }

    deinit {
        loadTask?.cancel()
    }

    func loadLibrary() async {
        do {
            let recent = try await projects.recentProjects(limit: 50)
            var items: [LibraryProjectItem] = []
            items.reserveCapacity(recent.count)
            for project in recent {
                let projectTakes = try await takes.takes(projectID: project.id)
                items.append(
                    LibraryProjectItem(
                        project: project,
                        takeCount: projectTakes.count,
                        lastRecordedAt: projectTakes.map(\.createdAt).max()
                    )
                )
            }
            libraryItems = items.sorted { $0.activityDate > $1.activityDate }
        } catch is CancellationError {
            return
        } catch {
            state = .failed(
                FileLoadFailure(
                    message: "Library could not be loaded.",
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

    func openLibraryItem(_ item: LibraryProjectItem) {
        let project = item.project
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
                await loadLibrary()
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
            await loadLibrary()
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
                await loadLibrary()
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
