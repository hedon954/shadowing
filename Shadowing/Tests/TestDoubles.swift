import Foundation
@testable import Shadowing

actor InMemoryPersistence {
    private var projects: [UUID: AudioProject] = [:]
    private var takes: [UUID: Take] = [:]
    private var settings: [String: Data] = [:]

    func recentProjects(limit: Int) throws -> [AudioProject] {
        guard limit >= 0 else {
            throw RepositoryError.invalidLimit(limit)
        }
        return Array(
            projects.values
                .sorted {
                    if $0.lastOpenedAt == $1.lastOpenedAt {
                        return $0.id.uuidString < $1.id.uuidString
                    }
                    return $0.lastOpenedAt > $1.lastOpenedAt
                }
                .prefix(limit)
        )
    }

    func project(id: UUID) -> AudioProject? {
        projects[id]
    }

    func save(project: AudioProject) {
        projects[project.id] = project
    }

    func deleteProject(id: UUID) {
        projects[id] = nil
        takes = takes.filter { $0.value.projectID != id }
    }

    func projectTakes(projectID: UUID) -> [Take] {
        takes.values
            .filter { $0.projectID == projectID }
            .sorted { $0.sequence < $1.sequence }
    }

    func save(take: Take) throws {
        guard projects[take.projectID] != nil else {
            throw TestDoubleError.missingProject
        }
        takes[take.id] = take
    }

    func deleteTake(id: UUID) {
        takes[id] = nil
    }

    func setting(for key: String) -> Data? {
        settings[key]
    }

    func setSetting(_ value: Data?, for key: String) {
        settings[key] = value
    }
}

struct InMemoryProjectRepository: ProjectRepository {
    let storage: InMemoryPersistence

    func recentProjects(limit: Int) async throws -> [AudioProject] {
        try await storage.recentProjects(limit: limit)
    }

    func project(id: UUID) async throws -> AudioProject? {
        await storage.project(id: id)
    }

    func save(_ project: AudioProject) async throws {
        await storage.save(project: project)
    }

    func deleteProject(id: UUID) async throws {
        await storage.deleteProject(id: id)
    }
}

struct InMemoryTakeRepository: TakeRepository {
    let storage: InMemoryPersistence

    func takes(projectID: UUID) async throws -> [Take] {
        await storage.projectTakes(projectID: projectID)
    }

    func save(_ take: Take) async throws {
        try await storage.save(take: take)
    }

    func deleteTake(id: UUID) async throws {
        await storage.deleteTake(id: id)
    }
}

struct InMemorySettingsStore: SettingsStore {
    let storage: InMemoryPersistence

    func value<Value: Sendable & Codable>(
        for key: String,
        as _: Value.Type
    ) async throws -> Value? {
        guard let data = await storage.setting(for: key) else {
            return nil
        }
        return try JSONDecoder().decode(Value.self, from: data)
    }

    func set(
        _ value: (some Sendable & Codable)?,
        for key: String
    ) async throws {
        let data = try value.map { try JSONEncoder().encode($0) }
        await storage.setSetting(data, for: key)
    }
}

struct AlwaysPlayableRecordingValidator: RecordingFileValidating {
    func validatePlayableRecording(at _: URL) throws {}
}

actor FailingTakeRepository: TakeRepository {
    private(set) var saveAttempts = 0

    func takes(projectID _: UUID) async throws -> [Take] {
        []
    }

    func save(_: Take) async throws {
        saveAttempts += 1
        throw TestDoubleError.forcedFailure
    }

    func deleteTake(id _: UUID) async throws {}
}

actor PracticeAudioClientSpy: PracticeAudioClient {
    private(set) var commands: [PracticeAudioCommand] = []
    private let stream: AsyncStream<PracticeAudioEvent>
    private let continuation: AsyncStream<PracticeAudioEvent>.Continuation

    init() {
        let pair = AsyncStream<PracticeAudioEvent>.makeStream()
        stream = pair.stream
        continuation = pair.continuation
    }

    func execute(_ command: PracticeAudioCommand) async throws {
        commands.append(command)
    }

    func eventStream() async -> AsyncStream<PracticeAudioEvent> {
        stream
    }

    func emit(_ event: PracticeAudioEvent) {
        continuation.yield(event)
    }
}

enum TestDoubleError: Error {
    case missingProject
    case forcedFailure
}
