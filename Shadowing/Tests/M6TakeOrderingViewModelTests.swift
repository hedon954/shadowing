import Foundation
@testable import Shadowing
import XCTest

@MainActor
final class M6TakeOrderingViewModelTests: XCTestCase {
    func testReorderTakesPersistsDisplayOrderWithoutChangingSequence() async throws {
        let pair = try await M6TestSupport.makeFixtureWithCommittedTake()
        let root = pair.temporaryRoot
        addTeardownBlock {
            try FileManager.default.removeItem(at: root)
        }
        let fixture = pair.fixture
        let existing = try XCTUnwrap(fixture.viewModel.activeTake)
        fixture.viewModel.clearTakeSelection()
        let commandCountBefore = await fixture.audio.commands.count
        fixture.viewModel.startRecording()
        let temporaryURL = await M6TestSupport.waitForBeginRecording(
            audio: fixture.audio,
            afterCommandCount: commandCountBefore
        )
        try Data([4, 4, 4, 4]).write(to: temporaryURL)
        await fixture.audio.emit(.recordingStarted)
        await fixture.audio.emit(
            .recordingFinished(
                url: temporaryURL,
                duration: 1.2,
                reason: .manual
            )
        )
        await M6TestSupport.waitUntil {
            fixture.viewModel.takes.count == 2
        }

        let top = try XCTUnwrap(fixture.viewModel.takes.first)
        let bottom = try XCTUnwrap(fixture.viewModel.takes.last)
        XCTAssertNotEqual(top.id, existing.id)
        XCTAssertNotEqual(top.id, bottom.id)

        fixture.viewModel.reorderTakes(draggedID: bottom.id, onto: top.id)
        await M6TestSupport.waitUntilAsync {
            let storedIDs = await (try? fixture.takes.takes(projectID: fixture.project.id))?
                .map(\.id)
            return storedIDs == [bottom.id, top.id]
        }

        XCTAssertEqual(fixture.viewModel.takes.map(\.id), [bottom.id, top.id])
        XCTAssertEqual(fixture.viewModel.takes.map(\.sequence), [bottom.sequence, top.sequence])
        XCTAssertEqual(fixture.viewModel.takes.map(\.displayOrder), [0, 1])
        let stored = try await fixture.takes.takes(projectID: fixture.project.id)
        XCTAssertEqual(stored.map(\.id), [bottom.id, top.id])
    }
}
