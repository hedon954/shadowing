@testable import Shadowing
import XCTest

final class WaveformTimelineTests: XCTestCase {
    func testZoomKeepsAnchorAtSameViewportFraction() {
        let viewport = TimelineViewport(start: 20, duration: 40, sourceDuration: 100)

        let zoomed = viewport.zoomed(
            by: 2,
            anchor: 30,
            sourceDuration: 100
        )

        XCTAssertEqual(zoomed.duration, 20, accuracy: 0.0001)
        XCTAssertEqual(zoomed.start, 25, accuracy: 0.0001)
        XCTAssertEqual((30 - zoomed.start) / zoomed.duration, 0.25, accuracy: 0.0001)
    }

    func testPanAndZoomClampToSourceBounds() {
        let viewport = TimelineViewport(start: 0, duration: 20, sourceDuration: 100)

        XCTAssertEqual(
            viewport.panned(by: -50, sourceDuration: 100).start,
            0,
            accuracy: 0.0001
        )
        XCTAssertEqual(
            viewport.panned(by: 200, sourceDuration: 100).end,
            100,
            accuracy: 0.0001
        )
        XCTAssertEqual(
            viewport.zoomed(by: 1000, anchor: 10, sourceDuration: 100).duration,
            TimelineViewport.minimumVisibleDuration,
            accuracy: 0.0001
        )
    }

    func testCoveringExpandsViewportToIncludeRecordingProgress() {
        let viewport = TimelineViewport(start: 11, duration: 3, sourceDuration: 120)

        let expanded = viewport.covering(
            start: 11,
            end: 21,
            sourceDuration: 120,
            trailingPadding: 0.5
        )

        XCTAssertEqual(expanded.start, 11, accuracy: 0.0001)
        XCTAssertEqual(expanded.end, 21.5, accuracy: 0.0001)
        XCTAssertTrue(expanded.contains(11))
        XCTAssertTrue(expanded.contains(21))
    }

    func testCoveringKeepsEarlierViewportStartAndClampsToSourceEnd() {
        let viewport = TimelineViewport(start: 5, duration: 4, sourceDuration: 30)

        let expanded = viewport.covering(
            start: 8,
            end: 40,
            sourceDuration: 30,
            trailingPadding: 1
        )

        XCTAssertEqual(expanded.start, 5, accuracy: 0.0001)
        XCTAssertEqual(expanded.end, 30, accuracy: 0.0001)
    }

    func testResizingEdgesZoomsViewportWhileClampingBounds() {
        let viewport = TimelineViewport(start: 20, duration: 40, sourceDuration: 100)

        let narrowedStart = viewport.resizing(edge: .start, to: 30, sourceDuration: 100)
        XCTAssertEqual(narrowedStart.start, 30, accuracy: 0.0001)
        XCTAssertEqual(narrowedStart.end, 60, accuracy: 0.0001)

        let narrowedEnd = viewport.resizing(edge: .end, to: 45, sourceDuration: 100)
        XCTAssertEqual(narrowedEnd.start, 20, accuracy: 0.0001)
        XCTAssertEqual(narrowedEnd.end, 45, accuracy: 0.0001)

        let widened = viewport.resizing(edge: .end, to: 200, sourceDuration: 100)
        XCTAssertEqual(widened.end, 100, accuracy: 0.0001)

        let minimum = viewport.resizing(edge: .start, to: 70, sourceDuration: 100)
        XCTAssertEqual(
            minimum.duration,
            TimelineViewport.minimumVisibleDuration,
            accuracy: 0.0001
        )
        XCTAssertEqual(minimum.end, 60, accuracy: 0.0001)
    }

    func testSamplerSelectsFinestUsefulLevelForVisibleWindow() {
        let levels = [
            makeLevel(framesPerPoint: 256, count: 2000),
            makeLevel(framesPerPoint: 1024, count: 500),
            makeLevel(framesPerPoint: 4096, count: 125)
        ]

        let selected = WaveformEnvelopeSampler.selectLevel(
            levels,
            sampleRate: 48000,
            visibleDuration: 10,
            targetPointCount: 500
        )

        XCTAssertEqual(selected.framesPerPoint, 256)
    }

    func testSamplerAggregatesMinimumAndMaximumWithoutLosingTransients() {
        let points = [
            WaveformEnvelopePoint(minimum: -0.2, maximum: 0.1),
            WaveformEnvelopePoint(minimum: -0.8, maximum: 0.4),
            WaveformEnvelopePoint(minimum: -0.1, maximum: 0.9),
            WaveformEnvelopePoint(minimum: -0.3, maximum: 0.2)
        ]

        let aggregated = WaveformEnvelopeSampler.aggregate(points, maximumCount: 2)

        XCTAssertEqual(aggregated.count, 2)
        XCTAssertEqual(aggregated[0].minimum, -0.8, accuracy: 0.0001)
        XCTAssertEqual(aggregated[0].maximum, 0.4, accuracy: 0.0001)
        XCTAssertEqual(aggregated[1].minimum, -0.3, accuracy: 0.0001)
        XCTAssertEqual(aggregated[1].maximum, 0.9, accuracy: 0.0001)
    }

    func testTakeLocalZeroMapsToOriginalRegionStart() throws {
        let region = try PracticeRegion(start: 12, end: 16, sourceDuration: 60)
        let waveform = WaveformPresentation(
            duration: 4,
            sampleRate: 1,
            levels: [makeLevel(framesPerPoint: 1, count: 4)],
            warning: nil
        )
        let viewport = TimelineViewport(
            start: region.start,
            duration: region.duration,
            sourceDuration: 60
        )

        let slice = WaveformEnvelopeSampler.slice(
            from: waveform,
            assetTimelineStart: region.start,
            visibleRange: viewport,
            targetPointCount: 100
        )

        XCTAssertEqual(slice.timelineStart, region.start, accuracy: 0.0001)
        XCTAssertEqual(slice.timelineDuration, region.duration, accuracy: 0.0001)
        XCTAssertEqual(slice.points.count, 4)
    }

    func testSixtyMinuteViewportKeepsRenderedPointCountBounded() {
        let duration: TimeInterval = 60 * 60
        let sampleRate = 48000.0
        let waveform = WaveformPresentation(
            duration: duration,
            sampleRate: sampleRate,
            levels: [
                makeLevel(
                    framesPerPoint: 256,
                    count: Int(duration * sampleRate / 256)
                ),
                makeLevel(
                    framesPerPoint: 4096,
                    count: Int(duration * sampleRate / 4096)
                ),
                makeLevel(
                    framesPerPoint: 16384,
                    count: Int(duration * sampleRate / 16384)
                )
            ],
            warning: nil
        )

        let slice = WaveformEnvelopeSampler.slice(
            from: waveform,
            visibleRange: .full(sourceDuration: duration),
            targetPointCount: 4096
        )

        XCTAssertEqual(slice.points.count, 4096)
        XCTAssertEqual(slice.timelineDuration, duration, accuracy: 0.001)
    }

    private func makeLevel(
        framesPerPoint: Int,
        count: Int
    ) -> WaveformEnvelopeLevel {
        WaveformEnvelopeLevel(
            framesPerPoint: framesPerPoint,
            points: Array(
                repeating: WaveformEnvelopePoint(
                    minimum: -0.5,
                    maximum: 0.5
                ),
                count: count
            )
        )
    }
}
