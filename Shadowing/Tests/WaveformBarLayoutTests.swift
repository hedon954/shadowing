import CoreGraphics
@testable import Shadowing
import XCTest

/// v6 waveform: discrete 2 pt bars with 1.5 pt gaps, mirrored, accent once played.
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
        XCTAssertEqual(bars[0].rect.height, 72 * 0.92 * 0.5, accuracy: 0.001)
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
