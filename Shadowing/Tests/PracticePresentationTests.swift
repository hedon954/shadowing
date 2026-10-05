@testable import Shadowing
import XCTest

@MainActor
final class PracticePresentationTests: XCTestCase {
    func testHeaderShowsTakeCountAndNewestTakeDate() throws {
        let viewModel = makeViewModel()
        XCTAssertEqual(viewModel.headerStatus, .takes(count: 0, lastPracticed: nil))

        let older = try makeTake(viewModel, sequence: 1, createdAt: 1000)
        let newer = try makeTake(viewModel, sequence: 2, createdAt: 5000)
        viewModel.takes = [newer, older]

        XCTAssertEqual(
            viewModel.headerStatus,
            .takes(count: 2, lastPracticed: Date(timeIntervalSince1970: 5000))
        )
    }

    func testEmptyTakesStateShowsUntilTheFirstRecordingStarts() throws {
        let viewModel = makeViewModel()
        XCTAssertTrue(viewModel.showsEmptyTakesState)

        viewModel.recordingPresentation = .countingDown(remainingSeconds: 3)
        XCTAssertFalse(viewModel.showsEmptyTakesState, "the live row replaces it")

        viewModel.recordingPresentation = .idle
        viewModel.takes = try [makeTake(viewModel, sequence: 1, createdAt: 1000)]
        XCTAssertFalse(viewModel.showsEmptyTakesState)
    }

    func testRecordingNumberIsAlwaysTheNextTakeEvenWithATakeSelected() throws {
        let viewModel = makeViewModel()
        let first = try makeTake(viewModel, sequence: 1, createdAt: 1000)
        let third = try makeTake(viewModel, sequence: 3, createdAt: 3000)
        viewModel.takes = [third, first]

        viewModel.recordingPresentation = .recording(elapsed: 4)
        XCTAssertEqual(viewModel.headerStatus, .recording(takeNumber: 4))
        XCTAssertTrue(viewModel.showsLiveTakeRow)

        viewModel.activeTake = first
        XCTAssertEqual(viewModel.headerStatus, .recording(takeNumber: 4), "ADR-0012: never replaces Take 1")

        viewModel.recordingPresentation = .countingDown(remainingSeconds: 2)
        XCTAssertEqual(viewModel.headerStatus, .countingDown(takeNumber: 4, remainingSeconds: 2))

        viewModel.recordingPresentation = .checkingPermission
        XCTAssertEqual(viewModel.headerStatus, .checkingMicrophone)
        XCTAssertFalse(viewModel.showsLiveTakeRow)
    }

    func testRulerUsesRoundTimesPlusBothEnds() {
        let ticks = WaveformRuler.ticks(
            for: TimelineViewport(start: 0, duration: 1249, sourceDuration: 1249)
        )
        XCTAssertEqual(ticks, [0, 300, 600, 900, 1249], "20:00 is too close to 20:49")
        let short = WaveformRuler.ticks(for: TimelineViewport(start: 0, duration: 130, sourceDuration: 130))
        XCTAssertEqual(short, [0, 30, 60, 90, 130], "like the v8 mockup: 0:00 0:30 1:00 1:30 2:10")

        let zoomed = WaveformRuler.ticks(
            for: TimelineViewport(start: 100, duration: 40, sourceDuration: 1249)
        )
        XCTAssertEqual(zoomed, [100, 110, 120, 130, 140])
    }

    func testClockTextFormatsPositionsAndDurations() {
        XCTAssertEqual(ClockText.paddedPosition(192.6), "03:12")
        XCTAssertEqual(ClockText.paddedPosition(1249), "20:49")
        XCTAssertEqual(ClockText.duration(252), "4:12")
        XCTAssertEqual(ClockText.duration(3725), "1:02:05")
        XCTAssertEqual(PracticeRateText.label(1), "1.0×")
        XCTAssertEqual(PracticeRateText.label(0.75), "0.75×")
    }

    func testZoomStateFollowsTheViewport() {
        let viewModel = makeViewModel()
        XCTAssertFalse(viewModel.isTimelineZoomed)
        viewModel.timelineViewport = TimelineViewport(start: 10, duration: 20, sourceDuration: 60)
        XCTAssertTrue(viewModel.isTimelineZoomed)
    }

    private func makeViewModel() -> PracticeViewModel {
        let storage = InMemoryPersistence()
        let prepared = M7TestSupport.makePreparedPractice(playhead: 0)
        return PracticeViewModel(
            prepared: prepared,
            audioClient: PracticeAudioClientSpy(),
            projects: InMemoryProjectRepository(storage: storage),
            sessionPreparer: FixedSessionPreparer(prepared: prepared)
        )
    }

    private func makeTake(
        _ viewModel: PracticeViewModel,
        sequence: Int,
        createdAt: TimeInterval
    ) throws -> Take {
        try Take(
            projectID: viewModel.project.id,
            region: PracticeRegion(id: UUID(), persistedTakeStart: 0, end: 10),
            sequence: sequence,
            relativeAudioPath: "take-\(sequence).caf",
            duration: 10,
            createdAt: Date(timeIntervalSince1970: createdAt)
        )
    }
}
