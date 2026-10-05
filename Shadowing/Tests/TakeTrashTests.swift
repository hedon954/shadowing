@testable import Shadowing
import XCTest

/// ⌘⌫ moves a take to the Trash and ⌘Z brings it back. A temporary folder stands in for
/// the real Trash.
final class TakeTrashTests: XCTestCase {
    private func makeFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("TakeTrashTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: folder)
        }
        return folder
    }

    private func makeTake() throws -> Take {
        try Take(
            projectID: UUID(),
            region: PracticeRegion.takeAlignment(start: 1, end: 3, sourceDuration: 10),
            sequence: 2,
            displayOrder: -2,
            relativeAudioPath: "p/take.caf",
            duration: 2,
            createdAt: Date(timeIntervalSince1970: 1000)
        )
    }

    func testTrashThenRestorePutsEveryFileBackAndSkipsMissingOnes() throws {
        let folder = try makeFolder()
        let audio = folder.appendingPathComponent("rec/take.caf")
        let offset = folder.appendingPathComponent("rec/take.json")
        let records = audio.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: records, withIntermediateDirectories: true)
        try Data([1, 2, 3]).write(to: audio)
        try Data("{}".utf8).write(to: offset)
        let missing = folder.appendingPathComponent("rec/none.json")

        let trashed = try TakeTrash.trash(
            [audio, offset, missing],
            take: makeTake(),
            using: .folder(folder.appendingPathComponent("Trash"))
        )
        XCTAssertEqual(trashed.files.map(\.original), [audio, offset])
        XCTAssertFalse(FileManager.default.fileExists(atPath: audio.path))
        XCTAssertTrue(trashed.files.allSatisfy { FileManager.default.fileExists(atPath: $0.trashed.path) })

        try TakeTrash.restore(trashed)
        XCTAssertEqual(try Data(contentsOf: audio), Data([1, 2, 3]))
        XCTAssertEqual(try Data(contentsOf: offset), Data("{}".utf8))
    }

    func testRestoreFailsWithoutMovingAnythingWhenTheTrashWasEmptied() throws {
        let folder = try makeFolder()
        let audio = folder.appendingPathComponent("take.caf")
        let offset = folder.appendingPathComponent("take.json")
        try Data([1]).write(to: audio)
        try Data([2]).write(to: offset)
        let trashed = try TakeTrash.trash(
            [audio, offset],
            take: makeTake(),
            using: .folder(folder.appendingPathComponent("T"))
        )
        try FileManager.default.removeItem(at: trashed.files[0].trashed)

        XCTAssertThrowsError(try TakeTrash.restore(trashed)) { error in
            XCTAssertEqual(error as? TakeTrashError, .notInTrash(sequence: 2))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: offset.path), "nothing restored")
        XCTAssertTrue(FileManager.default.fileExists(atPath: trashed.files[1].trashed.path))
    }

    @MainActor
    func testDeleteThenUndoGivesBackTheSameTakeAudioAndOffset() async throws {
        let fixture = try await M9TestSupport.makeFixtureWithCommittedTake(testCase: self, measuredOffset: 0.2)
        let undo = UndoManager()
        undo.groupsByEvent = false
        fixture.viewModel.undoManager = undo
        let take = try XCTUnwrap(fixture.viewModel.takes.first)
        let store = LocalRecordingAlignmentStore(rootDirectory: fixture.fileStore.rootURL)
        await M9TestSupport.waitUntil { store.offset(for: take.id) > 0 }
        let audioURL = try fixture.fileStore.audioURL(relativePath: take.relativeAudioPath)
        let audio = try Data(contentsOf: audioURL)

        await fixture.viewModel.deleteTake(take)
        XCTAssertTrue(fixture.viewModel.takes.isEmpty)
        let deletedRow = try await fixture.takes.take(id: take.id)
        XCTAssertNil(deletedRow)
        XCTAssertFalse(FileManager.default.fileExists(atPath: audioURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.url(for: take.id).path))
        XCTAssertTrue(undo.canUndo)
        XCTAssertTrue(undo.undoActionName.contains("1"), undo.undoActionName)

        undo.undo()
        await M9TestSupport.waitUntil { fixture.viewModel.activeTake?.id == take.id }

        let restoredRow = try await fixture.takes.take(id: take.id)
        XCTAssertEqual(restoredRow, take, "same id and fields")
        XCTAssertEqual(fixture.viewModel.takes.first, take)
        XCTAssertEqual(try Data(contentsOf: audioURL), audio)
        XCTAssertEqual(store.offset(for: take.id), 0.2, accuracy: 1e-9)
        XCTAssertEqual(fixture.viewModel.alignmentOffset(for: take.id), 0.2, accuracy: 1e-9)
        XCTAssertEqual(fixture.viewModel.activeTake?.id, take.id)
    }

    @MainActor
    func testUndoAfterTheTrashWasEmptiedShowsAnErrorAndKeepsTheTakeDeleted() async throws {
        let fixture = try await M9TestSupport.makeFixtureWithCommittedTake(testCase: self, measuredOffset: 0.2)
        let undo = UndoManager()
        undo.groupsByEvent = false
        fixture.viewModel.undoManager = undo
        let take = try XCTUnwrap(fixture.viewModel.takes.first)
        let store = LocalRecordingAlignmentStore(rootDirectory: fixture.fileStore.rootURL)
        await M9TestSupport.waitUntil { store.offset(for: take.id) > 0 }

        await fixture.viewModel.deleteTake(take)
        let trash = fixture.fileStore.rootURL.appendingPathComponent(".TestTrash", isDirectory: true)
        try FileManager.default.removeItem(at: trash)

        undo.undo()
        await M9TestSupport.waitUntil { fixture.viewModel.failure != nil }

        XCTAssertEqual(
            fixture.viewModel.failure?.message,
            TakeTrashError.notInTrash(sequence: take.sequence).localizedDescription
        )
        let row = try await fixture.takes.take(id: take.id)
        XCTAssertNil(row, "no row without its recording")
        XCTAssertTrue(fixture.viewModel.takes.isEmpty)
    }
}
