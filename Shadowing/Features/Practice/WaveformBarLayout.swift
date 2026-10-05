import CoreGraphics
import SwiftUI

/// Discrete, mirrored bars instead of a filled envelope (v6 design).
struct WaveformBarStyle: Equatable {
    var width: CGFloat
    var gap: CGFloat
    var cornerRadius: CGFloat = 1
    var minimumHeight: CGFloat = 2
    /// Share of the track height the loudest bar may fill.
    var heightFraction: CGFloat = 0.92
    /// Empty band above and below the bars; the playhead still spans it.
    var verticalInset: CGFloat = 0

    /// Original waveform: 2 pt bars, 1.5 pt gaps.
    static let original = WaveformBarStyle(width: 2, gap: 1.5, verticalInset: 6)
    /// Take rows: 1.5 pt bars, 1.2 pt gaps.
    static let mini = WaveformBarStyle(width: 1.5, gap: 1.2, minimumHeight: 1.5)
}

struct WaveformBarSample: Equatable {
    /// Horizontal position in points.
    var position: CGFloat
    /// Normalized loudness, 0...1.
    var value: CGFloat
}

struct WaveformBar: Equatable {
    var rect: CGRect
    var isPlayed: Bool
}

enum WaveformBarLayout {
    /// Places one bar per slot across `size`. `samples` carry 0...1 loudness.
    /// Slots without samples get no bar; bars whose centre is left of `playedX` are played.
    static func bars(
        samples: [WaveformBarSample],
        size: CGSize,
        style: WaveformBarStyle,
        playedX: CGFloat?
    ) -> [WaveformBar] {
        let step = style.width + style.gap
        let barArea = max(size.height - style.verticalInset * 2, 0)
        guard size.width > 0, barArea > 0, step > 0, !samples.isEmpty else {
            return []
        }
        let count = max(Int((size.width + style.gap) / step), 1)
        var peaks = [CGFloat?](repeating: nil, count: count)
        for sample in samples {
            let index = Int(sample.position / step)
            guard index >= 0, index < count else {
                continue
            }
            peaks[index] = max(peaks[index] ?? 0, sample.value)
        }
        let maxHeight = barArea * style.heightFraction
        return peaks.enumerated().compactMap { index, peak in
            guard let peak else {
                return nil
            }
            let height = min(max(peak * maxHeight, style.minimumHeight), barArea)
            let originX = CGFloat(index) * step
            let rect = CGRect(
                x: originX,
                y: (size.height - height) / 2,
                width: style.width,
                height: height
            )
            let isPlayed = playedX.map { rect.midX <= $0 } ?? false
            return WaveformBar(rect: rect, isPlayed: isPlayed)
        }
    }

    static func draw(
        _ bars: [WaveformBar],
        style: WaveformBarStyle,
        context: GraphicsContext,
        color: Color,
        playedColor: Color?
    ) {
        var unplayed = Path()
        var played = Path()
        for bar in bars {
            let shape = Path(
                roundedRect: bar.rect,
                cornerSize: CGSize(width: style.cornerRadius, height: style.cornerRadius)
            )
            if bar.isPlayed, playedColor != nil {
                played.addPath(shape)
            } else {
                unplayed.addPath(shape)
            }
        }
        context.fill(unplayed, with: .color(color))
        if let playedColor {
            context.fill(played, with: .color(playedColor))
        }
    }
}
