import CoreGraphics
@testable import Shadowing
import XCTest

/// v6 waveform: discrete 2 pt bars with 1.5 pt gaps, mirrored, accent once played; heights are
/// per-bar RMS normalized to the 95th percentile.
final class WaveformBarLayoutTests: XCTestCase {
    private func samples(count: Int, width: CGFloat, value: CGFloat = 0.5) -> [WaveformBarSample] {
        (0 ..< count).map { index in
            WaveformBarSample(position: width * (CGFloat(index) + 0.5) / CGFloat(count), value: value)
        }
    }

    func testOriginalBarsAreTwoPointsWideWithGapsAndMirrored() {
        let size = CGSize(width: 350, height: 84)
        let bars = WaveformBarLayout.bars(
            samples: samples(count: 700, width: 350),
            size: size,
            style: .original,
            playedX: nil
        )
        XCTAssertEqual(bars.count, 100, "350 pt fits 100 slots of 3.5 pt")
        for (index, bar) in bars.enumerated() {
            XCTAssertEqual(bar.rect.width, 2)
            XCTAssertEqual(bar.rect.minX, CGFloat(index) * 3.5, accuracy: 0.001)
            XCTAssertEqual(bar.rect.midY, size.height / 2, accuracy: 0.001, "bars are mirrored")
            XCTAssertFalse(bar.isPlayed)
        }
        // Even loudness is the 95th percentile itself, so every bar reaches the full height.
        XCTAssertTrue(bars.allSatisfy { abs($0.rect.height - 72 * 0.92) < 0.001 })
    }

    /// One loud spike (a cough, a clap) among normal speech: dividing by the peak squashes the
    /// speech to a tenth of the height, dividing by the 95th percentile keeps it readable.
    func testOneLoudSpikeDoesNotFlattenTheRest() throws {
        var levels = [CGFloat](repeating: 0.1, count: 99)
        levels.insert(1, at: 50)

        let peak = try XCTUnwrap(levels.max())
        let peakNormalized = levels.map { $0 / peak }
        let normalized = WaveformBarLayout.normalizedLevels(levels).compactMap(\.self)

        XCTAssertLessThan(median(peakNormalized), 0.15, "plain peak normalization flattens the speech")
        XCTAssertGreaterThan(median(normalized), 0.9, "95th percentile keeps it readable")
        XCTAssertEqual(normalized[50], 1, "the spike is clamped, not taller than the track")
    }

    func testEachBarIsTheRMSOfItsSamplesNotTheLoudestOne() {
        // One slot (3.5 pt) with a single click and three silent samples: RMS 0.5, peak 1.
        let samples = [1, 0, 0, 0].enumerated().map { index, value in
            WaveformBarSample(position: CGFloat(index) * 0.5, value: CGFloat(value))
        } + [WaveformBarSample(position: 4, value: 1)]
        let bars = WaveformBarLayout.bars(
            samples: samples,
            size: CGSize(width: 7, height: 84),
            style: .original,
            playedX: nil
        )
        XCTAssertEqual(bars.count, 2)
        XCTAssertEqual(bars[0].rect.height, 72 * 0.92 * 0.5, accuracy: 0.001)
        XCTAssertEqual(bars[1].rect.height, 72 * 0.92, accuracy: 0.001)
    }

    private func median(_ values: [CGFloat]) -> CGFloat {
        values.sorted()[values.count / 2]
    }

    func testBarsStayInsideTheSeventyTwoPointBandAndKeepAMinimumHeight() {
        let loud = WaveformBarLayout.bars(
            samples: samples(count: 10, width: 35, value: 1),
            size: CGSize(width: 35, height: 84),
            style: .original,
            playedX: nil
        )
        let silent = WaveformBarLayout.bars(
            samples: samples(count: 10, width: 35, value: 0),
            size: CGSize(width: 35, height: 84),
            style: .original,
            playedX: nil
        )
        for bar in loud {
            XCTAssertGreaterThanOrEqual(bar.rect.minY, 6)
            XCTAssertLessThanOrEqual(bar.rect.maxY, 78)
        }
        XCTAssertTrue(silent.allSatisfy { $0.rect.height == 2 })
    }

    func testBarsLeftOfThePlayheadArePlayed() {
        let bars = WaveformBarLayout.bars(
            samples: samples(count: 200, width: 350),
            size: CGSize(width: 350, height: 84),
            style: .original,
            playedX: 175
        )
        let played = bars.filter(\.isPlayed)
        XCTAssertEqual(played.count, 50)
        XCTAssertTrue(played.allSatisfy { $0.rect.midX <= 175 })
        XCTAssertTrue(bars.filter { !$0.isPlayed }.allSatisfy { $0.rect.midX > 175 })
    }

    func testSlotsWithoutSamplesStayEmpty() {
        let bars = WaveformBarLayout.bars(
            samples: [WaveformBarSample(position: 1, value: 0.4), WaveformBarSample(position: 40, value: 0.4)],
            size: CGSize(width: 100, height: 26),
            style: .mini,
            playedX: nil
        )
        XCTAssertEqual(bars.count, 2)
        XCTAssertEqual(bars.map(\.rect.width), [1.5, 1.5])
    }
}
