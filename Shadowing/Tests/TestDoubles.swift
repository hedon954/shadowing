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
            .sorted {
                if $0.displayOrder == $1.displayOrder {
                    return $0.sequence < $1.sequence
                }
                return $0.displayOrder < $1.displayOrder
            }
    }

    func take(id: UUID) -> Take? {
        takes[id]
    }

    func save(take: Take) throws {
        guard projects[take.projectID] != nil else {
            throw TestDoubleError.missingProject
        }
        takes[take.id] = take
    }

    func reorderTakes(_ orderedTakes: [Take]) {
        for take in orderedTakes {
            takes[take.id] = take
        }
    }

    func deleteTake(id: UUID) {
        takes[id] = nil
    }

    /// Mirrors the SQLite unique keys: id, (project, number), (project, position).
    func restoreTake(_ take: Take, moveFiles: @Sendable () throws -> Void) throws {
        let clash = takes.values.contains {
            $0.id == take.id
                || ($0.projectID == take.projectID && $0.sequence == take.sequence)
                || ($0.projectID == take.projectID && $0.displayOrder == take.displayOrder)
        }
        guard !clash else {
            throw TestDoubleError.uniqueConstraint
        }
        try moveFiles()
        takes[take.id] = take
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

    func take(id: UUID) async throws -> Take? {
        await storage.take(id: id)
    }

    func save(_ take: Take) async throws {
        try await storage.save(take: take)
    }

    func reorderTakes(_ orderedTakes: [Take]) async throws {
        await storage.reorderTakes(orderedTakes)
    }

    func deleteTake(id: UUID) async throws {
        await storage.deleteTake(id: id)
    }

    func restoreTake(_ take: Take, moveFiles: @escaping @Sendable () throws -> Void) async throws {
        try await storage.restoreTake(take, moveFiles: moveFiles)
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

    func take(id _: UUID) async throws -> Take? {
        nil
    }

    func save(_: Take) async throws {
        saveAttempts += 1
        throw TestDoubleError.forcedFailure
    }

    func reorderTakes(_: [Take]) async throws {
        throw TestDoubleError.forcedFailure
    }

    func deleteTake(id _: UUID) async throws {}

    func restoreTake(_: Take, moveFiles _: @escaping @Sendable () throws -> Void) async throws {
        throw TestDoubleError.forcedFailure
    }
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

    private var holdsNextSeek = false
    private var heldSeek: CheckedContinuation<Void, Never>?

    private var nextSeekFailure: Error?

    func execute(_ command: PracticeAudioCommand) async throws {
        commands.append(command)
        if case .seek = command, let failure = nextSeekFailure {
            nextSeekFailure = nil
            throw failure
        }
        if case .seek = command, holdsNextSeek {
            holdsNextSeek = false
            await withCheckedContinuation { heldSeek = $0 }
        }
        if case .pause = command, holdsNextPause {
            holdsNextPause = false
            await withCheckedContinuation { heldSeek = $0 }
        }
        if case .playTake = command {
            if let failure = nextPlayTakeFailure {
                nextPlayTakeFailure = nil
                throw failure
            }
            if holdsNextPlayTake {
                holdsNextPlayTake = false
                await withCheckedContinuation { heldSeek = $0 }
            }
        }
    }

    private var holdsNextPlayTake = false
    private var holdsNextPause = false

    /// Like `holdNextSeek`, for the next `.pause` (released with `releaseHeldSeek()`).
    func holdNextPause() {
        holdsNextPause = true
    }

    private var nextPlayTakeFailure: Error?

    /// Like `holdNextSeek`, for the next `.playTake` (released with `releaseHeldSeek()`).
    func holdNextPlayTake() {
        holdsNextPlayTake = true
    }

    /// The next `.playTake` is recorded, then throws `error`.
    func failNextPlayTake(with error: Error) {
        nextPlayTakeFailure = error
    }

    nonisolated func eventStream() -> AsyncStream<PracticeAudioEvent> {
        stream
    }

    /// The next seek is recorded but does not return until `releaseHeldSeek()`, so a test can
    /// deliver events while the engine has not applied it yet.
    func holdNextSeek() {
        holdsNextSeek = true
    }

    /// The next seek is recorded, then throws `error` instead of being applied.
    func failNextSeek(with error: Error) {
        nextSeekFailure = error
    }

    func releaseHeldSeek() {
        heldSeek?.resume()
        heldSeek = nil
    }

    func emit(_ event: PracticeAudioEvent) {
        continuation.yield(event)
    }
}

enum TestDoubleError: Error {
    case missingProject
    case forcedFailure
    case uniqueConstraint
}
