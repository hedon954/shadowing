import GRDB
@testable import Shadowing
import XCTest

final class AppDatabaseTests: XCTestCase {
    func testInitialMigrationCreatesExpectedTables() throws {
        let database = try DatabaseQueue()
        try AppDatabase.makeMigrator().migrate(database)

        let tables = try database.read { database in
            try String.fetchAll(
                database,
                sql: """
                SELECT name
                FROM sqlite_master
                WHERE type = 'table'
                ORDER BY name
                """
            )
        }

        XCTAssertTrue(tables.contains("projects"))
        XCTAssertTrue(tables.contains("takes"))
        XCTAssertTrue(tables.contains("settings"))
        XCTAssertTrue(tables.contains("grdb_migrations"))

        let columns = try database.read { database in
            try Row.fetchAll(database, sql: "PRAGMA table_info(projects)").map { row in
                String(row["name"])
            }
        }
        XCTAssertTrue(columns.contains("playback_rate"))
        XCTAssertTrue(columns.contains("script_display_name"))

        let takeColumns = try database.read { database in
            try Row.fetchAll(database, sql: "PRAGMA table_info(takes)").map { row in
                String(row["name"])
            }
        }
        XCTAssertTrue(takeColumns.contains("display_order"))
    }

    func testMigrationIsIdempotent() throws {
        let database = try DatabaseQueue()
        let migrator = AppDatabase.makeMigrator()

        try migrator.migrate(database)
        try migrator.migrate(database)
    }
}
