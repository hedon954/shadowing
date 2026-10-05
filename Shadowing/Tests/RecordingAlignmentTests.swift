import Foundation
@testable import Shadowing
import XCTest

/// Take offsets: measured at record time, saved as `Recordings/<take id>.json`, never an error.
final class RecordingAlignmentTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = try M9TestSupport.makeTemporaryRoot()
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testMeasuredOffsetAddsBothLatenciesAndIsClamped() {
        XCTAssertEqual(
            RecordingAlignment.measuredOffset(
                micFirstBufferSeconds: 100,
                playerStartSeconds: 100.12,
                outputLatency: 0.01,
                inputLatency: 0.005
            ),
            0.135,
            accuracy: 1e-9
        )
        XCTAssertEqual(RecordingAlignment.clamped(3), 1)
        XCTAssertEqual(RecordingAlignment.clamped(-3), -1)
        XCTAssertEqual(RecordingAlignment.clamped(.nan), 0)
    }

    func testTakeAndSourceTimesRoundTrip() {
        let local = RecordingAlignment.takeTime(forSourceTime: 50, regionStart: 48, offset: 0.2)
        XCTAssertEqual(local, 2.2, accuracy: 1e-9)
        let source = RecordingAlignment.sourceTime(forTakeTime: local, regionStart: 48, offset: 0.2)
        XCTAssertEqual(source, 50, accuracy: 1e-9)
    }

    func testStoreSavesLoadsAndDeletesSidecar() throws {
        let store = LocalRecordingAlignmentStore(rootDirectory: root)
        let id = UUID()
        try store.saveOffset(0.25, for: id)
        XCTAssertEqual(store.url(for: id).lastPathComponent, "\(id.uuidString).json")
        XCTAssertEqual(store.offset(for: id), 0.25, accuracy: 1e-9)
        store.deleteOffset(for: id)
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.url(for: id).path))
    }

    func testMissingBrokenOrOutOfRangeSidecarIsTreatedSafely() throws {
        let store = LocalRecordingAlignmentStore(rootDirectory: root)
        let missing = UUID()
        XCTAssertEqual(store.offset(for: missing), 0, "old takes have no file")

        let broken = UUID()
        try Data("{oops".utf8).write(to: store.url(for: broken))
        XCTAssertEqual(store.offset(for: broken), 0)

        let huge = UUID()
        try Data(#"{"version":1,"offsetSeconds":7.5}"#.utf8).write(to: store.url(for: huge))
        XCTAssertEqual(store.offset(for: huge), 1, "clamped to ±1 s")
        store.deleteOffset(for: missing)
    }

    @MainActor
    func testRecordingSavesTheMeasuredOffsetAndDeletingTheTakeRemovesIt() async throws {
        let fixture = try await M9TestSupport.makeFixtureWithCommittedTake(testCase: self, measuredOffset: 0.2)
        let take = try XCTUnwrap(fixture.viewModel.takes.first)
        let store = LocalRecordingAlignmentStore(rootDirectory: fixture.fileStore.rootURL)
        await M9TestSupport.waitUntil { store.offset(for: take.id) > 0 }
        XCTAssertEqual(store.offset(for: take.id), 0.2, accuracy: 1e-9)
        XCTAssertEqual(fixture.viewModel.alignmentOffset(for: take.id), 0.2, accuracy: 1e-9)

        await fixture.viewModel.deleteTake(take)
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.url(for: take.id).path))
        XCTAssertNil(fixture.viewModel.takeOffsets[take.id])
    }
}
