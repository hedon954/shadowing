import Foundation

protocol ProjectRepository: Sendable {
    func recentProjects(limit: Int) async throws -> [AudioProject]
    func project(id: UUID) async throws -> AudioProject?
    func save(_ project: AudioProject) async throws
    func deleteProject(id: UUID) async throws
}

protocol TakeRepository: Sendable {
    func takes(projectID: UUID) async throws -> [Take]
    func save(_ take: Take) async throws
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
    func commitTemporaryTake(at temporaryURL: URL, projectID: UUID, takeID: UUID) throws -> String
    func audioURL(relativePath: String) throws -> URL
    func deleteAudio(relativePath: String) throws
}

protocol BookmarkStore: Sendable {
    func createBookmark(for url: URL) throws -> Data
    func resolveBookmark(_ data: Data) throws -> ResolvedBookmark
}

struct ResolvedBookmark: Sendable {
    let url: URL
    let isStale: Bool
}
