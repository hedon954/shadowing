@testable import Shadowing
import XCTest

final class PracticeSessionStateMachineTests: XCTestCase {
    func testTransitionsFromPracticeThroughRecordingToComparison() throws {
        let project = makeProject()
        let region = try PracticeRegion(start: 2, end: 7, sourceDuration: project.duration)
        let take = try makeTake(projectID: project.id, region: region)
        var machine = PracticeSessionStateMachine()

        XCTAssertEqual(
            try machine.handle(.openProject(project)),
            [.projectOpened(projectID: project.id)]
        )
        XCTAssertEqual(try machine.handle(.selectRegion(region)), [.regionChanged(region)])
        XCTAssertEqual(
            try machine.handle(.prepareRecording),
            [.recordingPreparationRequested(region: region)]
        )
        XCTAssertEqual(try machine.handle(.beginCountdown(seconds: 3)), [])
        XCTAssertEqual(try machine.handle(.countdownTick(remainingSeconds: 2)), [])
        XCTAssertEqual(
            try machine.handle(.countdownTick(remainingSeconds: 0)),
            [.recordingCaptureRequested(region: region)]
        )
        XCTAssertEqual(try machine.handle(.updateRecordingElapsed(4)), [])
        XCTAssertEqual(try machine.handle(.stopRecording), [.recordingStopRequested])
        XCTAssertEqual(
            try machine.handle(.recordingCommitted(take)),
            [.comparisonReady(takeID: take.id)]
        )

        guard case let .comparing(comparison) = machine.state else {
            return XCTFail("Expected comparison state")
        }
        XCTAssertEqual(comparison.selectedTake, take)
        XCTAssertEqual(comparison.mode, .selectedTake)
    }

    func testRecordingRequiresASelectedRegion() throws {
        var machine = PracticeSessionStateMachine()
        try machine.handle(.openProject(makeProject()))

        XCTAssertThrowsError(try machine.handle(.prepareRecording)) { error in
            XCTAssertEqual(error as? PracticeTransitionError, .missingPracticeRegion)
        }
    }

    func testRejectsPracticeIntentDuringRecording() throws {
        let project = makeProject()
        let region = try PracticeRegion(start: 0, end: 2, sourceDuration: project.duration)
        var machine = PracticeSessionStateMachine()
        try machine.handle(.openProject(project))
        try machine.handle(.selectRegion(region))
        try machine.handle(.prepareRecording)

        XCTAssertThrowsError(try machine.handle(.play(at: 0))) { error in
            XCTAssertEqual(
                error as? PracticeTransitionError,
                .invalidTransition(from: .recording, intent: .play)
            )
        }
    }

    func testRejectsTakeThatDoesNotMatchActiveRecording() throws {
        let project = makeProject()
        let otherProject = makeProject()
        let region = try PracticeRegion(start: 1, end: 3, sourceDuration: project.duration)
        let take = try makeTake(projectID: otherProject.id, region: region)
        var machine = PracticeSessionStateMachine()
        try machine.handle(.openProject(project))
        try machine.handle(.selectRegion(region))
        try machine.handle(.prepareRecording)
        try machine.handle(.beginCountdown(seconds: 0))
        try machine.handle(.stopRecording)

        XCTAssertThrowsError(try machine.handle(.recordingCommitted(take))) { error in
            XCTAssertEqual(
                error as? PracticeTransitionError,
                .takeDoesNotMatchRecording
            )
        }
    }

    func testRerecordPreservesTakeAndReturnsToRecordingPreparation() throws {
        let project = makeProject()
        let region = try PracticeRegion(start: 1, end: 3, sourceDuration: project.duration)
        let take = try makeTake(projectID: project.id, region: region)
        var machine = PracticeSessionStateMachine()
        try machine.handle(.openProject(project))
        try machine.handle(.selectRegion(region))
        try machine.handle(.prepareRecording)
        try machine.handle(.beginCountdown(seconds: 0))
        try machine.handle(.stopRecording)
        try machine.handle(.recordingCommitted(take))

        XCTAssertEqual(
            try machine.handle(.rerecord),
            [.recordingPreparationRequested(region: region)]
        )
        XCTAssertEqual(
            machine.state,
            .recording(
                RecordingState(projectID: project.id, region: region, phase: .preparing)
            )
        )
    }

    private func makeProject() -> AudioProject {
        AudioProject(
            id: UUID(),
            sourceDisplayName: "source.mp3",
            sourceBookmark: Data([1, 2, 3]),
            duration: 120,
            playhead: 0,
            currentRegion: nil,
            selectedTakeID: nil,
            keptTakeID: nil,
            lastOpenedAt: Date(timeIntervalSince1970: 100)
        )
    }

    private func makeTake(projectID: UUID, region: PracticeRegion) throws -> Take {
        try Take(
            projectID: projectID,
            region: region,
            sequence: 1,
            relativeAudioPath: "projects/\(projectID)/take.caf",
            duration: region.duration,
            createdAt: Date(timeIntervalSince1970: 200)
        )
    }
}
