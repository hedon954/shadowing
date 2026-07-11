import Combine
import Foundation

@MainActor
final class RecordingsViewModel: ObservableObject {
    @Published private(set) var items: [RecordingListItem] = []
    @Published private(set) var isLoading = false
    @Published var failureMessage: String?

    private let projects: any ProjectRepository
    private let takes: any TakeRepository
    private let sessionPreparer: any PracticeSessionPreparing
    private let fileChooser: any AudioFileChoosing
    private let onPracticeReady: @MainActor (PreparedPractice) -> Void
    private var openTask: Task<Void, Never>?

    init(
        projects: any ProjectRepository,
        takes: any TakeRepository,
        sessionPreparer: any PracticeSessionPreparing,
        fileChooser: any AudioFileChoosing,
        onPracticeReady: @escaping @MainActor (PreparedPractice) -> Void
    ) {
        self.projects = projects
        self.takes = takes
        self.sessionPreparer = sessionPreparer
        self.fileChooser = fileChooser
        self.onPracticeReady = onPracticeReady
    }

    deinit {
        openTask?.cancel()
    }

    func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            let recent = try await projects.recentProjects(limit: 100)
            var collected: [RecordingListItem] = []
            for project in recent {
                let projectTakes = try await takes.takes(projectID: project.id)
                guard let latest = projectTakes.max(by: { $0.createdAt < $1.createdAt }) else {
                    continue
                }
                collected.append(
                    RecordingListItem(
                        project: project,
                        takeCount: projectTakes.count,
                        lastRecordedAt: latest.createdAt
                    )
                )
            }
            items = collected.sorted { $0.lastRecordedAt > $1.lastRecordedAt }
        } catch is CancellationError {
            return
        } catch {
            failureMessage = error.localizedDescription
        }
    }

    func open(_ item: RecordingListItem) {
        openTask?.cancel()
        openTask = Task { [weak self] in
            guard let self else {
                return
            }
            do {
                let prepared = try await sessionPreparer.prepareExistingProject(
                    id: item.project.id
                )
                try Task.checkCancellation()
                onPracticeReady(prepared)
            } catch is CancellationError {
                return
            } catch {
                failureMessage = error.localizedDescription
            }
        }
    }

    func openAudio() {
        openTask?.cancel()
        openTask = Task { [weak self] in
            guard let self, let url = await fileChooser.chooseMP3() else {
                return
            }
            do {
                let prepared = try await sessionPreparer.prepareNewSource(at: url)
                try Task.checkCancellation()
                onPracticeReady(prepared)
            } catch is CancellationError {
                return
            } catch {
                failureMessage = error.localizedDescription
            }
        }
    }
}
