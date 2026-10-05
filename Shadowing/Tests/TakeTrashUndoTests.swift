import GRDB
@testable import Shadowing
import XCTest

/// Undo of ⌘⌫ when something changed in between: a new take reused the number, the row
/// cannot go back, or a file cannot move back. A temporary folder stands in for the Trash.
@MainActor
final class TakeTrashUndoTests: XCTestCase {
    // MARK: - View model

    func testDeleteThenRecordThenUndoDoesNothingAndKeepsTheNewTake() async throws {
        let fixture = try await M9TestSupport.makeFixtureWithCommittedTake(testCase: self, measuredOffset: 0.2)
        let undo = Self.makeUndoManager(for: fixture)
        let deleted = try XCTUnwrap(fixture.viewModel.takes.first)
        await fixture.viewModel.deleteTake(deleted)
        XCTAssertTrue(undo.canUndo)

        let recorded = try await Self.recordTake(fixture)
        XCTAssertEqual(recorded.sequence, deleted.sequence, "the new take reuses the number")
        XCTAssertFalse(undo.canUndo, "recording clears the delete's Undo")

        undo.undo()
        await Task.yield()
        let takes = try await fixture.takes.takes(projectID: fixture.project.id)
        XCTAssertEqual(takes.map(\.id), [recorded.id])
        let audio = try fixture.fileStore.audioURL(relativePath: recorded.relativeAudioPath)
        XCTAssertEqual(try Data(contentsOf: audio), Data([5, 5, 5, 5]), "the new recording is untouched")
        XCTAssertNil(fixture.viewModel.failure)
    }

    func testUndoThatClashesWithANewerTakeShowsAShortErrorAndMovesNothing() async throws {
        let fixture = try await M9TestSupport.makeFixtureWithCommittedTake(testCase: self, measuredOffset: 0.2)
        let undo = Self.makeUndoManager(for: fixture)
        let deleted = try XCTUnwrap(fixture.viewModel.takes.first)
        let audio = try fixture.fileStore.audioURL(relativePath: deleted.relativeAudioPath)
        await fixture.viewModel.deleteTake(deleted)
        // A take with the same number saved behind the view model's back (Undo still registered).
        let clash = try Take(
            projectID: deleted.projectID, region: deleted.region, sequence: deleted.sequence,
            displayOrder: deleted.displayOrder - 1, relativeAudioPath: "other.caf",
            duration: 1, createdAt: Date()
        )
        try await fixture.takes.save(clash)

        undo.undo()
        await M9TestSupport.waitUntil { fixture.viewModel.failure != nil }

        XCTAssertEqual(
            fixture.viewModel.failure?.message,
            TakeTrashError.couldNotRestore(sequence: deleted.sequence).localizedDescription
        )
        let row = try await fixture.takes.take(id: deleted.id)
        XCTAssertNil(row)
        XCTAssertFalse(FileManager.default.fileExists(atPath: audio.path), "the audio stays in the Trash")
    }

    func testUndoBringsBackTheKeptSelectedTakeInItsPlace() async throws {
        let fixture = try await M9TestSupport.makeFixtureWithCommittedTake(testCase: self, measuredOffset: 0.2)
        let model = fixture.viewModel
        let first = try XCTUnwrap(model.takes.first)
        let second = try await Self.recordTake(fixture)
        let undo = Self.makeUndoManager(for: fixture)
        model.selectTake(first)
        model.keepThisTake()
        await M9TestSupport.waitUntil { model.takes.map(\.id) == [second.id, first.id] }
        XCTAssertEqual(model.takes.map(\.id), [second.id, first.id], "newest on top")

        await model.deleteTake(first)
        XCTAssertNil(model.project.keptTakeID)
        XCTAssertEqual(model.activeTake?.id, second.id)

        undo.undo()
        await M9TestSupport.waitUntil { model.activeTake?.id == first.id }

        XCTAssertEqual(model.takes.map(\.id), [second.id, first.id], "back in its place")
        XCTAssertEqual(model.takes.last?.sequence, first.sequence)
        XCTAssertEqual(model.project.keptTakeID, first.id, "kept again")
        XCTAssertEqual(model.project.selectedTakeID, first.id, "selected again")
        XCTAssertTrue(model.isCurrentTakeKept)
        await M9TestSupport.waitUntilAsync {
            await (try? fixture.projects.project(id: fixture.project.id))?.keptTakeID == first.id
        }
        let saved = try await fixture.projects.project(id: fixture.project.id)
        XCTAssertEqual(saved?.keptTakeID, first.id)
        XCTAssertEqual(saved?.selectedTakeID, first.id)
    }

    // MARK: - SQLite transaction

    func testRestoreWithAClashingNumberInsertsNothingAndMovesNothing() async throws {
        let (repository, project) = try await Self.makeDatabase()
        let folder = try makeFolder()
        let existing = try Self.makeTake(project: project, sequence: 3, displayOrder: -4, path: "a.caf")
        try await repository.save(existing)
        let deleted = try Self.makeTake(project: project, sequence: 3, displayOrder: -3, path: "b.caf")
        let trashed = try trashFiles(["b.caf", "b.json"], in: folder, take: deleted)

        do {
            try await repository.restoreTake(deleted) { try TakeTrash.restore(trashed) }
            XCTFail("Expected the restore to fail")
        } catch {}

        let row = try await repository.take(id: deleted.id)
        XCTAssertNil(row)
        for file in trashed.files {
            XCTAssertTrue(FileManager.default.fileExists(atPath: file.trashed.path), "still in the Trash")
            XCTAssertFalse(FileManager.default.fileExists(atPath: file.original.path))
        }
    }

    func testFailedFileMoveRollsBackTheRowAndReturnsMovedFilesToTheTrash() async throws {
        let (repository, project) = try await Self.makeDatabase()
        let folder = try makeFolder()
        let deleted = try Self.makeTake(project: project, sequence: 2, displayOrder: -2, path: "c.caf")
        let trashed = try trashFiles(["c.caf", "c.json"], in: folder, take: deleted)
        // Something now sits where the offset file goes back, so its move fails.
        try Data([9]).write(to: trashed.files[1].original)

        do {
            try await repository.restoreTake(deleted) { try TakeTrash.restore(trashed) }
            XCTFail("Expected the restore to fail")
        } catch {}

        let row = try await repository.take(id: deleted.id)
        XCTAssertNil(row, "the insert was rolled back")
        XCTAssertTrue(FileManager.default.fileExists(atPath: trashed.files[0].trashed.path), "audio back in Trash")
        XCTAssertFalse(FileManager.default.fileExists(atPath: trashed.files[0].original.path))
        XCTAssertEqual(try Data(contentsOf: trashed.files[1].original), Data([9]), "other file untouched")
    }

    // MARK: - Helpers

    private static func makeUndoManager(for fixture: M9Fixture) -> UndoManager {
        let undo = UndoManager()
        undo.groupsByEvent = false
        fixture.viewModel.undoManager = undo
        return undo
    }

    private static func recordTake(_ fixture: M9Fixture) async throws -> Take {
        let model = fixture.viewModel
        let before = model.takes.map(\.id)
        let commands = await fixture.audio.commands.count
        model.startRecording()
        let url = await M9TestSupport.waitForBeginRecording(audio: fixture.audio, afterCommandCount: commands)
        try Data([5, 5, 5, 5]).write(to: url)
        await fixture.audio.emit(.recordingStarted)
        await fixture.audio.emit(.recordingFinished(url: url, duration: 1.5, reason: .manual))
        await M9TestSupport.waitUntil { model.takes.contains { !before.contains($0.id) } }
        return try XCTUnwrap(model.takes.first { !before.contains($0.id) })
    }

    private static func makeDatabase() async throws -> (GRDBTakeRepository, AudioProject) {
        let database = try DatabaseQueue()
        try AppDatabase.makeMigrator().migrate(database)
        let project = M9TestSupport.makeProject(name: "Speech.mp3", openedAt: 100)
        try await GRDBProjectRepository(database: database).save(project)
        return (GRDBTakeRepository(database: database), project)
    }

    private static func makeTake(project: AudioProject, sequence: Int, displayOrder: Int, path: String) throws -> Take {
        try Take(
            projectID: project.id,
            region: PracticeRegion.takeAlignment(start: 1, end: 3, sourceDuration: project.duration),
            sequence: sequence,
            displayOrder: displayOrder,
            relativeAudioPath: path,
            duration: 2,
            createdAt: Date(timeIntervalSince1970: 1000)
        )
    }

    private func makeFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("TakeTrashUndoTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: folder)
        }
        return folder
    }

    private func trashFiles(_ names: [String], in folder: URL, take: Take) throws -> TrashedTake {
        let urls = names.map { folder.appendingPathComponent($0) }
        for url in urls {
            try Data([1, 2]).write(to: url)
        }
        return try TakeTrash.trash(urls, take: take, using: .folder(folder.appendingPathComponent("Trash")))
    }
}
