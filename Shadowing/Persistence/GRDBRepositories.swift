import Foundation
import GRDB

enum RepositoryError: Error, Equatable, LocalizedError, Sendable {
    case invalidLimit(Int)
    case corruptProject(id: String)
    case corruptTake(id: String)

    var errorDescription: String? {
        switch self {
        case let .invalidLimit(limit):
            "A repository query limit cannot be negative: \(limit)."
        case let .corruptProject(id):
            "Project \(id) contains invalid persisted data."
        case let .corruptTake(id):
            "Take \(id) contains invalid persisted data."
        }
    }
}

actor GRDBProjectRepository: ProjectRepository {
    private let database: any DatabaseWriter

    init(database: any DatabaseWriter) {
        self.database = database
    }

    func recentProjects(limit: Int) async throws -> [AudioProject] {
        guard limit >= 0 else {
            throw RepositoryError.invalidLimit(limit)
        }
        guard limit > 0 else {
            return []
        }

        return try await database.read { database in
            let rows = try Row.fetchAll(
                database,
                sql: """
                SELECT *
                FROM projects
                ORDER BY last_opened_at DESC, id ASC
                LIMIT ?
                """,
                arguments: [limit]
            )
            return try rows.map(Self.makeProject)
        }
    }

    func project(id: UUID) async throws -> AudioProject? {
        try await database.read { database in
            guard let row = try Row.fetchOne(
                database,
                sql: "SELECT * FROM projects WHERE id = ?",
                arguments: [id.uuidString]
            ) else {
                return nil
            }
            return try Self.makeProject(row)
        }
    }

    func save(_ project: AudioProject) async throws {
        guard project.duration.isFinite,
              project.duration >= 0,
              project.playhead.isFinite,
              project.playhead >= 0,
              project.playhead <= project.duration,
              project.playbackRate.isFinite,
              project.playbackRate > 0
        else {
            throw RepositoryError.corruptProject(id: project.id.uuidString)
        }

        try await database.write { database in
            try database.execute(
                sql: """
                INSERT INTO projects (
                    id,
                    source_display_name,
                    source_bookmark,
                    duration,
                    playhead,
                    region_id,
                    region_start,
                    region_end,
                    selected_take_id,
                    kept_take_id,
                    last_opened_at,
                    playback_rate
                )
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET
                    source_display_name = excluded.source_display_name,
                    source_bookmark = excluded.source_bookmark,
                    duration = excluded.duration,
                    playhead = excluded.playhead,
                    region_id = excluded.region_id,
                    region_start = excluded.region_start,
                    region_end = excluded.region_end,
                    selected_take_id = excluded.selected_take_id,
                    kept_take_id = excluded.kept_take_id,
                    last_opened_at = excluded.last_opened_at,
                    playback_rate = excluded.playback_rate
                """,
                arguments: [
                    project.id.uuidString,
                    project.sourceDisplayName,
                    project.sourceBookmark,
                    project.duration,
                    project.playhead,
                    project.currentRegion?.id.uuidString,
                    project.currentRegion?.start,
                    project.currentRegion?.end,
                    project.selectedTakeID?.uuidString,
                    project.keptTakeID?.uuidString,
                    project.lastOpenedAt,
                    project.playbackRate
                ]
            )
        }
    }

    func deleteProject(id: UUID) async throws {
        try await database.write { database in
            try database.execute(
                sql: "DELETE FROM projects WHERE id = ?",
                arguments: [id.uuidString]
            )
        }
    }

    private static func makeProject(_ row: Row) throws -> AudioProject {
        let persistedID: String = row["id"]
        guard let id = UUID(uuidString: persistedID) else {
            throw RepositoryError.corruptProject(id: persistedID)
        }

        let duration: TimeInterval = row["duration"]
        let playhead: TimeInterval = row["playhead"]
        let playbackRate: Double = row["playback_rate"]
        guard duration.isFinite,
              duration >= 0,
              playhead.isFinite,
              playhead >= 0,
              playhead <= duration,
              playbackRate.isFinite,
              playbackRate > 0
        else {
            throw RepositoryError.corruptProject(id: persistedID)
        }

        let region = try makeRegion(
            id: row["region_id"],
            start: row["region_start"],
            end: row["region_end"],
            ownerID: persistedID
        )
        let selectedTakeID = try makeOptionalUUID(
            row["selected_take_id"],
            ownerID: persistedID
        )
        let keptTakeID = try makeOptionalUUID(
            row["kept_take_id"],
            ownerID: persistedID
        )

        return AudioProject(
            id: id,
            sourceDisplayName: row["source_display_name"],
            sourceBookmark: row["source_bookmark"],
            duration: duration,
            playhead: playhead,
            currentRegion: region,
            selectedTakeID: selectedTakeID,
            keptTakeID: keptTakeID,
            lastOpenedAt: row["last_opened_at"],
            playbackRate: playbackRate
        )
    }

    private static func makeRegion(
        id: String?,
        start: TimeInterval?,
        end: TimeInterval?,
        ownerID: String
    ) throws -> PracticeRegion? {
        switch (id, start, end) {
        case (nil, nil, nil):
            return nil
        case let (.some(regionID), .some(start), .some(end)):
            guard let id = UUID(uuidString: regionID) else {
                throw RepositoryError.corruptProject(id: ownerID)
            }
            do {
                return try PracticeRegion(id: id, persistedStart: start, end: end)
            } catch {
                throw RepositoryError.corruptProject(id: ownerID)
            }
        default:
            throw RepositoryError.corruptProject(id: ownerID)
        }
    }

    private static func makeOptionalUUID(
        _ value: String?,
        ownerID: String
    ) throws -> UUID? {
        guard let value else {
            return nil
        }
        guard let id = UUID(uuidString: value) else {
            throw RepositoryError.corruptProject(id: ownerID)
        }
        return id
    }
}

actor GRDBTakeRepository: TakeRepository {
    private let database: any DatabaseWriter

    init(database: any DatabaseWriter) {
        self.database = database
    }

    func takes(projectID: UUID) async throws -> [Take] {
        try await database.read { database in
            let rows = try Row.fetchAll(
                database,
                sql: """
                SELECT *
                FROM takes
                WHERE project_id = ?
                ORDER BY sequence ASC
                """,
                arguments: [projectID.uuidString]
            )
            return try rows.map(Self.makeTake)
        }
    }

    func take(id: UUID) async throws -> Take? {
        try await database.read { database in
            guard let row = try Row.fetchOne(
                database,
                sql: """
                SELECT *
                FROM takes
                WHERE id = ?
                """,
                arguments: [id.uuidString]
            ) else {
                return nil
            }
            return try Self.makeTake(row)
        }
    }

    func save(_ take: Take) async throws {
        try await database.write { database in
            try database.execute(
                sql: """
                INSERT INTO takes (
                    id,
                    project_id,
                    region_id,
                    region_start,
                    region_end,
                    sequence,
                    relative_audio_path,
                    duration,
                    created_at
                )
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET
                    project_id = excluded.project_id,
                    region_id = excluded.region_id,
                    region_start = excluded.region_start,
                    region_end = excluded.region_end,
                    sequence = excluded.sequence,
                    relative_audio_path = excluded.relative_audio_path,
                    duration = excluded.duration,
                    created_at = excluded.created_at
                """,
                arguments: [
                    take.id.uuidString,
                    take.projectID.uuidString,
                    take.region.id.uuidString,
                    take.region.start,
                    take.region.end,
                    take.sequence,
                    take.relativeAudioPath,
                    take.duration,
                    take.createdAt
                ]
            )
        }
    }

    func deleteTake(id: UUID) async throws {
        try await database.write { database in
            try database.execute(
                sql: "DELETE FROM takes WHERE id = ?",
                arguments: [id.uuidString]
            )
        }
    }

    private static func makeTake(_ row: Row) throws -> Take {
        let persistedID: String = row["id"]
        let persistedProjectID: String = row["project_id"]
        let persistedRegionID: String = row["region_id"]

        guard let id = UUID(uuidString: persistedID),
              let projectID = UUID(uuidString: persistedProjectID),
              let regionID = UUID(uuidString: persistedRegionID)
        else {
            throw RepositoryError.corruptTake(id: persistedID)
        }

        do {
            let region = try PracticeRegion(
                id: regionID,
                persistedStart: row["region_start"],
                end: row["region_end"]
            )
            return try Take(
                id: id,
                projectID: projectID,
                region: region,
                sequence: row["sequence"],
                relativeAudioPath: row["relative_audio_path"],
                duration: row["duration"],
                createdAt: row["created_at"]
            )
        } catch {
            throw RepositoryError.corruptTake(id: persistedID)
        }
    }
}

actor GRDBSettingsStore: SettingsStore {
    private let database: any DatabaseWriter

    init(database: any DatabaseWriter) {
        self.database = database
    }

    func value<Value: Sendable & Codable>(
        for key: String,
        as _: Value.Type
    ) async throws -> Value? {
        let data: Data? = try await database.read { database in
            try Data.fetchOne(
                database,
                sql: "SELECT value FROM settings WHERE key = ?",
                arguments: [key]
            )
        }
        guard let data else {
            return nil
        }
        return try JSONDecoder().decode(Value.self, from: data)
    }

    func set(
        _ value: (some Sendable & Codable)?,
        for key: String
    ) async throws {
        guard let value else {
            try await database.write { database in
                try database.execute(
                    sql: "DELETE FROM settings WHERE key = ?",
                    arguments: [key]
                )
            }
            return
        }

        let data = try JSONEncoder().encode(value)
        try await database.write { database in
            try database.execute(
                sql: """
                INSERT INTO settings (key, value)
                VALUES (?, ?)
                ON CONFLICT(key) DO UPDATE SET value = excluded.value
                """,
                arguments: [key, data]
            )
        }
    }
}
