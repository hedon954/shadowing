import Foundation
import GRDB

enum AppDatabase {
    static func open(at url: URL) throws -> DatabasePool {
        var configuration = Configuration()
        configuration.foreignKeysEnabled = true

        let database = try DatabasePool(path: url.path, configuration: configuration)
        try makeMigrator().migrate(database)
        return database
    }

    static func makeMigrator() -> DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1-initial-schema", migrate: migrateV1InitialSchema)
        migrator.registerMigration("v2-project-playback-rate", migrate: migrateV2ProjectPlaybackRate)
        migrator.registerMigration("v3-take-display-order", migrate: migrateV3TakeDisplayOrder)
        return migrator
    }

    private static func migrateV1InitialSchema(_ database: Database) throws {
        try database.create(table: "projects") { table in
            table.column("id", .text).primaryKey()
            table.column("source_display_name", .text).notNull()
            table.column("source_bookmark", .blob).notNull()
            table.column("duration", .double).notNull()
            table.column("playhead", .double).notNull().defaults(to: 0)
            table.column("region_id", .text)
            table.column("region_start", .double)
            table.column("region_end", .double)
            table.column("selected_take_id", .text)
            table.column("kept_take_id", .text)
            table.column("last_opened_at", .datetime).notNull()
        }

        try database.create(table: "takes") { table in
            table.column("id", .text).primaryKey()
            table.column("project_id", .text)
                .notNull()
                .indexed()
                .references("projects", onDelete: .cascade)
            table.column("region_id", .text).notNull()
            table.column("region_start", .double).notNull()
            table.column("region_end", .double).notNull()
            table.column("sequence", .integer).notNull()
            table.column("relative_audio_path", .text).notNull().unique()
            table.column("duration", .double).notNull()
            table.column("created_at", .datetime).notNull()
            table.uniqueKey(["project_id", "sequence"])
        }

        try database.create(table: "settings") { table in
            table.column("key", .text).primaryKey()
            table.column("value", .blob).notNull()
        }

        try database.create(
            index: "projects_by_last_opened",
            on: "projects",
            columns: ["last_opened_at"]
        )
        try database.create(
            index: "takes_by_project_and_created",
            on: "takes",
            columns: ["project_id", "created_at"]
        )
    }

    private static func migrateV2ProjectPlaybackRate(_ database: Database) throws {
        try database.alter(table: "projects") { table in
            table.add(column: "playback_rate", .double).notNull().defaults(to: 1)
        }
    }

    private static func migrateV3TakeDisplayOrder(_ database: Database) throws {
        try database.alter(table: "takes") { table in
            table.add(column: "display_order", .integer).notNull().defaults(to: 0)
        }
        try database.execute(sql: "UPDATE takes SET display_order = sequence")
        try database.create(
            index: "takes_by_project_and_display_order",
            on: "takes",
            columns: ["project_id", "display_order"],
            options: .unique
        )
    }
}
