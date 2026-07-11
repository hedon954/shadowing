import Foundation
import GRDB
@testable import Shadowing
import XCTest

final class M7PersistenceTests: XCTestCase {
    func testRelocatePreservesProjectRegionAndTakes() async throws {
        let storage = InMemoryPersistence()
        let projects = InMemoryProjectRepository(storage: storage)
        let takes = InMemoryTakeRepository(storage: storage)
        let region = try PracticeRegion(start: 2, end: 7, sourceDuration: 40)
        let projectID = UUID()
        var project = AudioProject(
            id: projectID,
            sourceDisplayName: "old.mp3",
            sourceBookmark: Data([1]),
            duration: 40,
            playhead: 5,
            currentRegion: region,
            selectedTakeID: nil,
            keptTakeID: nil,
            lastOpenedAt: Date(timeIntervalSince1970: 10),
            playbackRate: 1.25
        )
        try await projects.save(project)
        let take = try Take(
            id: UUID(),
            projectID: projectID,
            region: region,
            sequence: 1,
            relativeAudioPath: "projects/\(projectID.uuidString)/a.caf",
            duration: 5,
            createdAt: Date(timeIntervalSince1970: 20)
        )
        try await takes.save(take)
        project.selectedTakeID = take.id
        try await projects.save(project)

        let access = M7BookmarkAccess(
            resolvedBookmark: ResolvedBookmark(
                url: URL(fileURLWithPath: "/tmp/relocated-source.mp3"),
                isStale: false
            )
        )
        let audio = PracticeAudioClientSpy()
        let loader = AudioProjectSessionLoader(
            projects: projects,
            bookmarks: M7BookmarkStore(access: access),
            validator: M7AcceptingValidator(),
            metadataLoader: M7MetadataLoader(
                metadata: AudioAssetMetadata(displayName: "relocated.mp3", duration: 40)
            ),
            waveformService: M7WaveformPreparer(),
            audioClient: audio,
            now: { Date(timeIntervalSince1970: 99) }
        )

        let prepared = try await loader.relocateProject(
            id: projectID,
            to: URL(fileURLWithPath: "/tmp/relocated-source.mp3")
        )

        XCTAssertEqual(prepared.project.id, projectID)
        XCTAssertEqual(prepared.project.sourceDisplayName, "relocated.mp3")
        XCTAssertEqual(prepared.project.currentRegion, region)
        XCTAssertEqual(prepared.project.selectedTakeID, take.id)
        XCTAssertEqual(prepared.project.playbackRate, 1.25)
        XCTAssertEqual(prepared.project.playhead, 5)
        let restoredTakes = try await takes.takes(projectID: projectID)
        XCTAssertEqual(restoredTakes, [take])
    }

    @MainActor
    func testMissingSourceSurfacesRelocateRecovery() async {
        let storage = InMemoryPersistence()
        let project = AudioProject(
            id: UUID(),
            sourceDisplayName: "Speech.mp3",
            sourceBookmark: Data([1]),
            duration: 60,
            playhead: 0,
            currentRegion: nil,
            selectedTakeID: nil,
            keptTakeID: nil,
            lastOpenedAt: Date(timeIntervalSince1970: 100)
        )
        await storage.save(project: project)
        var opened: PreparedPractice?
        let viewModel = FilesViewModel(
            chooser: M7Chooser(url: nil),
            sessionPreparer: M7FailingSessionPreparer(error: .fileMissing),
            projects: InMemoryProjectRepository(storage: storage)
        ) { prepared in
            opened = prepared
        }

        viewModel.openRecentProject(project)
        for _ in 0 ..< 200 where viewModel.state.failure == nil {
            await Task.yield()
        }

        XCTAssertNil(opened)
        XCTAssertEqual(viewModel.state.failure?.action, .relocate(project.id))
        XCTAssertEqual(viewModel.state.failure?.recoveryTitle, "Locate File")
    }

    func testOrphanedTemporaryFilesAreRemoved() throws {
        let root = try makeTemporaryRoot()
        let fileStore = LocalRecordingFileStore(rootDirectory: root)
        let orphanA = try fileStore.temporaryTakeURL(id: UUID())
        let orphanB = try fileStore.temporaryTakeURL(id: UUID())
        try Data([1]).write(to: orphanA)
        try Data([2, 3]).write(to: orphanB)

        let removed = try fileStore.removeOrphanedTemporaryTakes()

        XCTAssertEqual(removed, 2)
        XCTAssertFalse(FileManager.default.fileExists(atPath: orphanA.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: orphanB.path))
    }

    func testPlaybackRateMigrationDefaultsExistingProjects() throws {
        let database = try DatabaseQueue()
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1-initial-schema") { database in
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
        }
        try migrator.migrate(database)
        try database.write { database in
            try database.execute(
                sql: """
                INSERT INTO projects (
                    id, source_display_name, source_bookmark, duration, playhead, last_opened_at
                ) VALUES (?, ?, ?, ?, ?, ?)
                """,
                arguments: [
                    UUID().uuidString,
                    "legacy.mp3",
                    Data([1]),
                    30.0,
                    0.0,
                    Date(timeIntervalSince1970: 1)
                ]
            )
        }

        try AppDatabase.makeMigrator().migrate(database)
        let rate: Double = try database.read { database in
            try Double.fetchOne(database, sql: "SELECT playback_rate FROM projects") ?? -1
        }
        XCTAssertEqual(rate, 1)
    }

    private func makeTemporaryRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("Shadowing-M7P-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: root)
        }
        return root
    }
}

actor M7BookmarkAccess: BookmarkAccess {
    nonisolated let resolvedBookmark: ResolvedBookmark

    init(resolvedBookmark: ResolvedBookmark) {
        self.resolvedBookmark = resolvedBookmark
    }

    func stop() {}
}

struct M7BookmarkStore: BookmarkStore {
    let access: M7BookmarkAccess

    func createBookmark(for _: URL) throws -> Data {
        Data([9])
    }

    func beginAccess(to _: Data) async throws -> any BookmarkAccess {
        access
    }
}

struct M7AcceptingValidator: AudioFileValidating {
    func validate(_: URL) throws {}
}

struct M7MetadataLoader: AudioAssetMetadataLoading {
    let metadata: AudioAssetMetadata

    func loadMetadata(from _: URL) async throws -> AudioAssetMetadata {
        metadata
    }
}

struct M7WaveformPreparer: WaveformPreparing {
    func prepareWaveform(from _: URL) async throws -> WaveformPresentation {
        WaveformPresentation(peaks: [0.1, 0.2], warning: nil)
    }
}

struct M7Chooser: AudioFileChoosing {
    let url: URL?

    @MainActor
    func chooseMP3() async -> URL? {
        url
    }
}

actor M7FailingSessionPreparer: PracticeSessionPreparing {
    let error: AudioSourceError

    init(error: AudioSourceError) {
        self.error = error
    }

    func prepareNewSource(at _: URL) async throws -> PreparedPractice {
        throw error
    }

    func prepareExistingProject(id _: UUID) async throws -> PreparedPractice {
        throw error
    }

    func relocateProject(id _: UUID, to _: URL) async throws -> PreparedPractice {
        throw error
    }

    func endSession() {}
}
