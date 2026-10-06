import Foundation
import GRDB
@testable import Shadowing
import XCTest

/// The redesign once shipped `v5-project-timeline-viewport` (columns `timeline_visible_*`); the
/// main working copy has `v5-project-viewport-and-loop` (`loop_enabled`, `viewport_*`). hedon's
/// database has run both. Every starting point must migrate without error or data loss and end
/// up on the shared columns.
final class MigrationMergeTests: XCTestCase {
    private enum Applied {
        case redesignV5, mainV5
    }

    func testFreshDatabaseGetsTheSharedColumns() async throws {
        let database = try DatabaseQueue()
        try AppDatabase.makeMigrator().migrate(database)
        let columns = try projectColumns(database)
        XCTAssertTrue(columns.isSuperset(of: ["loop_enabled", "viewport_start", "viewport_duration"]))
        XCTAssertFalse(columns.contains("timeline_visible_start"))
        let applied = try await database.read { database in try AppDatabase.makeMigrator().appliedMigrations(database) }
        XCTAssertEqual(applied.suffix(3), [
            "v5-project-timeline-viewport", "v5-project-viewport-and-loop", "v6-copy-redesign-timeline-viewport"
        ])

        let repository = GRDBProjectRepository(database: database)
        var project = try makeProject()
        project.loopEnabled = true
        project.viewportStart = 40
        project.viewportDuration = 8
        try await repository.save(project)
        let loaded = try await repository.project(id: project.id)
        XCTAssertEqual(loaded, project)
    }

    /// hedon's database: both v5 steps already applied, in either branch's build.
    func testDatabaseWithBothV5MigrationsAppliedKeepsEverySavedZoom() throws {
        let database = try legacyDatabase(applied: [.redesignV5, .mainV5])
        try insertRow(database, id: "A", timelineVisible: (40, 8))
        try insertRow(database, id: "B", viewport: (10, 5), timelineVisible: (99, 1))
        try insertRow(database, id: "C", loopEnabled: true)

        try AppDatabase.makeMigrator().migrate(database)

        XCTAssertEqual(try viewport(database, id: "A")?.start, 40, "copied from the redesign columns")
        XCTAssertEqual(try viewport(database, id: "A")?.duration, 8)
        XCTAssertEqual(try viewport(database, id: "B")?.start, 10, "an existing shared value wins")
        XCTAssertEqual(try loopEnabled(database, id: "C"), true)
        XCTAssertTrue(try projectColumns(database).contains("timeline_visible_start"), "nothing is dropped")
        try AppDatabase.makeMigrator().migrate(database) // idempotent
    }

    /// A database only a redesign build has opened.
    func testDatabaseWithOnlyTheRedesignV5GetsTheSharedColumnsAndItsZoom() throws {
        let database = try legacyDatabase(applied: [.redesignV5])
        try insertRow(database, id: "A", timelineVisible: (40, 8))
        try AppDatabase.makeMigrator().migrate(database)
        XCTAssertEqual(try viewport(database, id: "A")?.start, 40)
        XCTAssertEqual(try loopEnabled(database, id: "A"), false)
    }

    /// A database only the main working copy has opened.
    func testDatabaseWithOnlyTheMainV5MigratesWithoutChanges() throws {
        let database = try legacyDatabase(applied: [.mainV5])
        try insertRow(database, id: "A", viewport: (12, 3), loopEnabled: true)
        try AppDatabase.makeMigrator().migrate(database)
        XCTAssertEqual(try viewport(database, id: "A")?.start, 12)
        XCTAssertEqual(try loopEnabled(database, id: "A"), true)
        XCTAssertFalse(try projectColumns(database).contains("timeline_visible_start"))
    }

    // MARK: - Helpers

    /// Migrated to v4, then the given v5 steps replayed as those builds ran them.
    private func legacyDatabase(applied: [Applied]) throws -> DatabaseQueue {
        let database = try DatabaseQueue()
        try AppDatabase.makeMigrator().migrate(database, upTo: "v4-project-script-display-name")
        try database.write { database in
            for step in applied {
                switch step {
                case .redesignV5:
                    try database.execute(sql: """
                    ALTER TABLE projects ADD COLUMN timeline_visible_start DOUBLE;
                    ALTER TABLE projects ADD COLUMN timeline_visible_duration DOUBLE;
                    INSERT INTO grdb_migrations (identifier) VALUES ('v5-project-timeline-viewport');
                    """)
                case .mainV5:
                    try database.execute(sql: """
                    ALTER TABLE projects ADD COLUMN loop_enabled BOOLEAN NOT NULL DEFAULT 0;
                    ALTER TABLE projects ADD COLUMN viewport_start DOUBLE;
                    ALTER TABLE projects ADD COLUMN viewport_duration DOUBLE;
                    INSERT INTO grdb_migrations (identifier) VALUES ('v5-project-viewport-and-loop');
                    """)
                }
            }
        }
        return database
    }

    private func insertRow(
        _ database: DatabaseQueue,
        id: String,
        viewport: (Double, Double)? = nil,
        timelineVisible: (Double, Double)? = nil,
        loopEnabled: Bool? = nil
    ) throws {
        try database.write { database in
            try database.execute(
                sql: """
                INSERT INTO projects (id, source_display_name, source_bookmark, duration, playhead, last_opened_at)
                VALUES (?, 'a.mp3', x'01', 129, 0, '2026-10-06 00:00:00')
                """,
                arguments: [id]
            )
            if let viewport {
                try database.execute(
                    sql: "UPDATE projects SET viewport_start = ?, viewport_duration = ? WHERE id = ?",
                    arguments: [viewport.0, viewport.1, id]
                )
            }
            if let timelineVisible {
                try database.execute(
                    sql: "UPDATE projects SET timeline_visible_start = ?, timeline_visible_duration = ? WHERE id = ?",
                    arguments: [timelineVisible.0, timelineVisible.1, id]
                )
            }
            if let loopEnabled {
                try database.execute(
                    sql: "UPDATE projects SET loop_enabled = ? WHERE id = ?",
                    arguments: [loopEnabled, id]
                )
            }
        }
    }

    private func viewport(_ database: DatabaseQueue, id: String) throws -> (start: Double, duration: Double)? {
        try database.read { database in
            let row = try Row.fetchOne(
                database,
                sql: "SELECT viewport_start, viewport_duration FROM projects WHERE id = ?",
                arguments: [id]
            )
            guard let row, let start: Double = row["viewport_start"], let duration: Double = row["viewport_duration"]
            else {
                return nil
            }
            return (start, duration)
        }
    }

    private func loopEnabled(_ database: DatabaseQueue, id: String) throws -> Bool? {
        try database.read { database in
            try Bool.fetchOne(database, sql: "SELECT loop_enabled FROM projects WHERE id = ?", arguments: [id])
        }
    }

    private func projectColumns(_ database: DatabaseQueue) throws -> Set<String> {
        try database.read { database in
            try Set(database.columns(in: "projects").map(\.name))
        }
    }

    private func makeProject() throws -> AudioProject {
        try AudioProject(
            id: UUID(),
            sourceDisplayName: "a.mp3",
            sourceBookmark: Data([1]),
            duration: 129,
            playhead: 62,
            currentRegion: PracticeRegion(start: 27, end: 30, sourceDuration: 129),
            selectedTakeID: nil,
            keptTakeID: nil,
            lastOpenedAt: Date(timeIntervalSince1970: 100)
        )
    }
}
