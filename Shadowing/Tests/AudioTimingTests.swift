@testable import Shadowing
import XCTest

final class AudioTimingTests: XCTestCase {
    func testFrameTimeRoundTripStaysWithinHalfFrame() throws {
        for sampleRate in [44100.0, 48000.0, 96000.0] {
            let converter = try AudioFrameTimeConverter(sampleRate: sampleRate)
            for time in [0, 0.001, 1.234_567, 60, 3600] {
                let frame = try converter.frame(at: time)
                let roundTrip = try converter.time(at: frame)
                XCTAssertLessThanOrEqual(
                    abs(roundTrip - time),
                    0.5 / sampleRate
                )
            }
        }
    }

    func testFiveThirtyAndSixtySecondRegionsHaveNoCumulativeSourceFrameDrift() throws {
        for sampleRate in [44100.0, 48000.0] {
            let converter = try AudioFrameTimeConverter(sampleRate: sampleRate)
            for duration in [5.0, 30.0, 60.0] {
                let region = try PracticeRegion(
                    start: 7.25,
                    end: 7.25 + duration,
                    sourceDuration: 120
                )
                let scheduler = try RegionLoopScheduler(
                    region: region,
                    converter: converter,
                    playbackRate: 1
                )
                let expectedLength = try converter.frame(at: region.end) -
                    converter.frame(at: region.start)

                for loopIndex in 0 ... 20 {
                    XCTAssertEqual(
                        try scheduler.sourceBoundaryFrame(afterLoop: loopIndex),
                        scheduler.regionStartFrame + expectedLength * Int64(loopIndex)
                    )
                }
            }
        }
    }

    func testOutputBoundariesAreCalculatedFromOriginAtEveryRate() throws {
        let converter = try AudioFrameTimeConverter(sampleRate: 44100)
        let region = try PracticeRegion(start: 0, end: 60, sourceDuration: 120)

        for rate in [0.5, 0.75, 1.0, 1.25, 1.5] {
            let scheduler = try RegionLoopScheduler(
                region: region,
                converter: converter,
                playbackRate: rate
            )
            for loopIndex in 0 ... 20 {
                let exact = Double(scheduler.regionFrameCount) * Double(loopIndex) *
                    48000 / 44100 / rate
                let scheduled = try scheduler.outputBoundaryFrame(
                    afterLoop: loopIndex,
                    outputSampleRate: 48000
                )
                XCTAssertLessThanOrEqual(abs(Double(scheduled) - exact), 0.5)
            }
        }
    }

    func testRateChangeReschedulesRemainingSourceFramesWithoutChangingBoundary() throws {
        let scheduler = try RegionLoopScheduler(
            regionStartFrame: 441_000,
            regionEndFrame: 2_646_000,
            sourceSampleRate: 44100,
            playbackRate: 1
        )
        let currentFrame: Int64 = 1_323_000

        let normalPlan = try scheduler.schedule(
            from: currentFrame,
            outputSampleRate: 48000
        )
        let slowPlan = try scheduler.schedule(
            from: currentFrame,
            outputSampleRate: 48000,
            rate: 0.5
        )

        XCTAssertEqual(normalPlan.sourceStartFrame, currentFrame)
        XCTAssertEqual(normalPlan.sourceFrameCount, scheduler.regionEndFrame - currentFrame)
        XCTAssertEqual(slowPlan.sourceFrameCount, normalPlan.sourceFrameCount)
        XCTAssertEqual(slowPlan.outputFrameCount, normalPlan.outputFrameCount * 2)
    }

    func testPlaybackSegmentPlanLoopsOnlyTheSelectedFrames() throws {
        let scheduler = try RegionLoopScheduler(
            regionStartFrame: 1000,
            regionEndFrame: 4000,
            sourceSampleRate: 1000,
            playbackRate: 1
        )

        let plan = try PlaybackSegmentPlanner.plan(
            from: 2500,
            sourceFrameCount: 10000,
            loopScheduler: scheduler
        )

        XCTAssertEqual(
            plan.initial,
            AudioSegment(startFrame: 2500, frameCount: 1500)
        )
        XCTAssertEqual(
            plan.repeated,
            AudioSegment(startFrame: 1000, frameCount: 3000)
        )
    }

    func testPlaybackSegmentPlanRestartsOutsideRequestAtLoopStart() throws {
        let scheduler = try RegionLoopScheduler(
            regionStartFrame: 1000,
            regionEndFrame: 4000,
            sourceSampleRate: 1000,
            playbackRate: 1
        )

        for requestedFrame in [0, 4000, 9000] {
            let plan = try PlaybackSegmentPlanner.plan(
                from: Int64(requestedFrame),
                sourceFrameCount: 10000,
                loopScheduler: scheduler
            )
            XCTAssertEqual(
                plan.initial,
                AudioSegment(startFrame: 1000, frameCount: 3000)
            )
        }
    }

    func testPlaybackSegmentPlanContinuesToSourceEndWhenLoopIsDisabled() throws {
        let plan = try PlaybackSegmentPlanner.plan(
            from: 2500,
            sourceFrameCount: 10000,
            loopScheduler: nil
        )

        XCTAssertEqual(
            plan.initial,
            AudioSegment(startFrame: 2500, frameCount: 7500)
        )
        XCTAssertNil(plan.repeated)
    }

    func testRejectsInvalidTimingInputs() {
        XCTAssertThrowsError(try AudioFrameTimeConverter(sampleRate: 0))
        XCTAssertThrowsError(
            try RegionLoopScheduler(
                regionStartFrame: 10,
                regionEndFrame: 10,
                sourceSampleRate: 48000,
                playbackRate: 1
            )
        )
        XCTAssertThrowsError(
            try RegionLoopScheduler(
                regionStartFrame: 0,
                regionEndFrame: 10,
                sourceSampleRate: 48000,
                playbackRate: 0
            )
        )
    }
}
