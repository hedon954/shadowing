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
    }

    func testMigrationIsIdempotent() throws {
        let database = try DatabaseQueue()
        let migrator = AppDatabase.makeMigrator()

        try migrator.migrate(database)
        try migrator.migrate(database)
    }
}
