import Foundation

protocol ProjectRepository: Sendable {
    func recentProjects(limit: Int) async throws -> [AudioProject]
    func project(id: UUID) async throws -> AudioProject?
    func save(_ project: AudioProject) async throws
    func deleteProject(id: UUID) async throws
}

protocol TakeRepository: Sendable {
    func takes(projectID: UUID) async throws -> [Take]
    func take(id: UUID) async throws -> Take?
    func save(_ take: Take) async throws
    /// Persists vertical order for the given takes (already ordered top → bottom).
    func reorderTakes(_ orderedTakes: [Take]) async throws
    func deleteTake(id: UUID) async throws
}

protocol SettingsStore: Sendable {
    func value<Value: Sendable & Codable>(
        for key: String,
        as type: Value.Type
    ) async throws -> Value?

    func set(
        _ value: (some Sendable & Codable)?,
        for key: String
    ) async throws
}

protocol RecordingFileStore: Sendable {
    func temporaryTakeURL(id: UUID) throws -> URL
    func discardTemporaryTake(at temporaryURL: URL) throws
    func commitTemporaryTake(
        at temporaryURL: URL,
        projectID: UUID,
        takeID: UUID,
        replaceExisting: Bool
    ) throws -> String
    func audioURL(relativePath: String) throws -> URL
    func deleteAudio(relativePath: String) throws
    /// Removes leftover files under the managed temporary directory.
    /// Returns the number of removed items.
    func removeOrphanedTemporaryTakes() throws -> Int
}

extension RecordingFileStore {
    func commitTemporaryTake(
        at temporaryURL: URL,
        projectID: UUID,
        takeID: UUID
    ) throws -> String {
        try commitTemporaryTake(
            at: temporaryURL,
            projectID: projectID,
            takeID: takeID,
            replaceExisting: false
        )
    }
}

protocol BookmarkStore: Sendable {
    func createBookmark(for url: URL) throws -> Data
    func beginAccess(to data: Data) async throws -> any BookmarkAccess
    func withAccess<Value: Sendable>(
        to data: Data,
        operation: @Sendable (ResolvedBookmark) async throws -> Value
    ) async throws -> Value
}

extension BookmarkStore {
    func withAccess<Value: Sendable>(
        to data: Data,
        operation: @Sendable (ResolvedBookmark) async throws -> Value
    ) async throws -> Value {
        let access = try await beginAccess(to: data)
        do {
            let value = try await operation(access.resolvedBookmark)
            await access.stop()
            return value
        } catch {
            await access.stop()
            throw error
        }
    }
}

protocol BookmarkAccess: Sendable {
    var resolvedBookmark: ResolvedBookmark { get async }
    func stop() async
}

struct ResolvedBookmark: Equatable, Sendable {
    let url: URL
    let isStale: Bool
}

struct TakeDraft: Equatable, Sendable {
    let id: UUID
    let projectID: UUID
    let region: PracticeRegion
    let sequence: Int
    let displayOrder: Int
    let duration: TimeInterval
    let createdAt: Date

    init(
        id: UUID = UUID(),
        projectID: UUID,
        region: PracticeRegion,
        sequence: Int,
        displayOrder: Int? = nil,
        duration: TimeInterval,
        createdAt: Date
    ) throws {
        guard sequence > 0,
              duration.isFinite,
              duration >= PracticeRegion.minimumDuration
        else {
            throw DomainError.invalidTake
        }

        self.id = id
        self.projectID = projectID
        self.region = region
        self.sequence = sequence
        self.displayOrder = displayOrder ?? sequence
        self.duration = duration
        self.createdAt = createdAt
    }

    func makeTake(relativeAudioPath: String) throws -> Take {
        try Take(
            id: id,
            projectID: projectID,
            region: region,
            sequence: sequence,
            displayOrder: displayOrder,
            relativeAudioPath: relativeAudioPath,
            duration: duration,
            createdAt: createdAt
        )
    }
}

protocol TakeCommitting: Sendable {
    func commit(
        _ draft: TakeDraft,
        temporaryFile: URL,
        replaceExisting: Bool
    ) async throws -> Take
}

extension TakeCommitting {
    func commit(_ draft: TakeDraft, temporaryFile: URL) async throws -> Take {
        try await commit(draft, temporaryFile: temporaryFile, replaceExisting: false)
    }
}
