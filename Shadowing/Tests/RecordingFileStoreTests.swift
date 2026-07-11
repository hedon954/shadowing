import GRDB
@testable import Shadowing
import XCTest

@MainActor
final class RecordingFileStoreTests: XCTestCase {
    func testCommitMovesTemporaryFileAndSavesMetadata() async throws {
        let root = try makeTemporaryDirectory()
        let fileStore = LocalRecordingFileStore(rootDirectory: root)
        let storage = InMemoryPersistence()
        let projects = InMemoryProjectRepository(storage: storage)
        let takes = InMemoryTakeRepository(storage: storage)
        let project = makeProject()
        try await projects.save(project)
        let draft = try makeDraft(projectID: project.id)
        let temporaryURL = try fileStore.temporaryTakeURL(id: draft.id)
        try Data([1, 2, 3]).write(to: temporaryURL)
        let committer = RecordingTakeCommitter(
            fileStore: fileStore,
            takeRepository: takes,
            validator: AlwaysPlayableRecordingValidator()
        )

        let take = try await committer.commit(draft, temporaryFile: temporaryURL)

        let committedURL = try fileStore.audioURL(relativePath: take.relativeAudioPath)
        XCTAssertFalse(FileManager.default.fileExists(atPath: temporaryURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: committedURL.path))
        let saved = try await takes.takes(projectID: project.id)
        XCTAssertEqual(saved, [take])
    }

    func testDatabaseFailureRemovesCommittedFile() async throws {
        let root = try makeTemporaryDirectory()
        let fileStore = LocalRecordingFileStore(rootDirectory: root)
        let database = try DatabaseQueue()
        try AppDatabase.makeMigrator().migrate(database)
        let repository = GRDBTakeRepository(database: database)
        let draft = try makeDraft(projectID: UUID())
        let temporaryURL = try fileStore.temporaryTakeURL(id: draft.id)
        try Data([1, 2, 3]).write(to: temporaryURL)
        let committer = RecordingTakeCommitter(
            fileStore: fileStore,
            takeRepository: repository,
            validator: AlwaysPlayableRecordingValidator()
        )

        do {
            _ = try await committer.commit(draft, temporaryFile: temporaryURL)
            XCTFail("Expected metadata save to fail")
        } catch let error as TakeCommitError {
            guard case .metadataSaveFailed = error else {
                return XCTFail("Expected metadataSaveFailed, got \(error)")
            }
        }

        let relativePath = "projects/\(draft.projectID.uuidString)/\(draft.id.uuidString).caf"
        let committedURL = try fileStore.audioURL(relativePath: relativePath)
        XCTAssertFalse(FileManager.default.fileExists(atPath: committedURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: temporaryURL.path))
    }

    func testEmptyTemporaryFileDoesNotReachRepository() async throws {
        let root = try makeTemporaryDirectory()
        let fileStore = LocalRecordingFileStore(rootDirectory: root)
        let repository = FailingTakeRepository()
        let draft = try makeDraft(projectID: UUID())
        let temporaryURL = try fileStore.temporaryTakeURL(id: draft.id)
        try Data().write(to: temporaryURL)
        let committer = RecordingTakeCommitter(
            fileStore: fileStore,
            takeRepository: repository,
            validator: AlwaysPlayableRecordingValidator()
        )

        do {
            _ = try await committer.commit(draft, temporaryFile: temporaryURL)
            XCTFail("Expected an empty recording error")
        } catch let error as RecordingFileStoreError {
            XCTAssertEqual(error, .temporaryFileEmpty(temporaryURL.path))
        }

        let saveAttempts = await repository.saveAttempts
        XCTAssertEqual(saveAttempts, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: temporaryURL.path))
    }

    func testRejectsTemporaryFileOutsideManagedDirectory() throws {
        let root = try makeTemporaryDirectory()
        let fileStore = LocalRecordingFileStore(rootDirectory: root)
        let unmanaged = root
            .deletingLastPathComponent()
            .appendingPathComponent("\(UUID()).caf")
        try Data([1]).write(to: unmanaged)
        addTeardownBlock {
            try FileManager.default.removeItem(at: unmanaged)
        }

        XCTAssertThrowsError(
            try fileStore.commitTemporaryTake(
                at: unmanaged,
                projectID: UUID(),
                takeID: UUID()
            )
        ) { error in
            XCTAssertEqual(
                error as? RecordingFileStoreError,
                .unmanagedTemporaryFile(unmanaged.path)
            )
        }
    }

    func testRejectsRelativePathTraversal() throws {
        let root = try makeTemporaryDirectory()
        let fileStore = LocalRecordingFileStore(rootDirectory: root)

        XCTAssertThrowsError(try fileStore.audioURL(relativePath: "../outside.caf")) { error in
            XCTAssertEqual(
                error as? RecordingFileStoreError,
                .invalidRelativePath("../outside.caf")
            )
        }
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ShadowingTests-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        addTeardownBlock {
            try FileManager.default.removeItem(at: directory)
        }
        return directory
    }

    private func makeProject() -> AudioProject {
        AudioProject(
            id: UUID(),
            sourceDisplayName: "source.mp3",
            sourceBookmark: Data([1]),
            duration: 60,
            playhead: 0,
            currentRegion: nil,
            selectedTakeID: nil,
            keptTakeID: nil,
            lastOpenedAt: Date(timeIntervalSince1970: 100)
        )
    }

    private func makeDraft(projectID: UUID) throws -> TakeDraft {
        let region = try PracticeRegion(start: 1, end: 3, sourceDuration: 60)
        return try TakeDraft(
            projectID: projectID,
            region: region,
            sequence: 1,
            duration: 2,
            createdAt: Date(timeIntervalSince1970: 200)
        )
    }
}
