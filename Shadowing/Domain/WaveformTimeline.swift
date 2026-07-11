import Foundation

struct TimelineViewport: Equatable, Sendable {
    static let minimumVisibleDuration: TimeInterval = 0.25

    let start: TimeInterval
    let duration: TimeInterval

    var end: TimeInterval {
        start + duration
    }

    init(start: TimeInterval, duration: TimeInterval, sourceDuration: TimeInterval) {
        let safeSourceDuration = max(sourceDuration, 0)
        let safeDuration = min(
            max(duration, min(Self.minimumVisibleDuration, safeSourceDuration)),
            safeSourceDuration
        )
        self.duration = safeDuration
        self.start = min(max(start, 0), max(safeSourceDuration - safeDuration, 0))
    }

    static func full(sourceDuration: TimeInterval) -> TimelineViewport {
        TimelineViewport(
            start: 0,
            duration: sourceDuration,
            sourceDuration: sourceDuration
        )
    }

    static func fitting(
        _ region: PracticeRegion,
        sourceDuration: TimeInterval,
        paddingFraction: Double = 0.08
    ) -> TimelineViewport {
        let padding = region.duration * min(max(paddingFraction, 0), 0.5)
        return TimelineViewport(
            start: region.start - padding,
            duration: region.duration + padding * 2,
            sourceDuration: sourceDuration
        )
    }

    func zoomed(
        by factor: Double,
        anchor: TimeInterval,
        sourceDuration: TimeInterval
    ) -> TimelineViewport {
        guard factor.isFinite, factor > 0, duration > 0 else {
            return self
        }
        let normalizedAnchor = min(max((anchor - start) / duration, 0), 1)
        let nextDuration = duration / factor
        let nextStart = anchor - nextDuration * normalizedAnchor
        return TimelineViewport(
            start: nextStart,
            duration: nextDuration,
            sourceDuration: sourceDuration
        )
    }

    func panned(
        by timeOffset: TimeInterval,
        sourceDuration: TimeInterval
    ) -> TimelineViewport {
        TimelineViewport(
            start: start + timeOffset,
            duration: duration,
            sourceDuration: sourceDuration
        )
    }

    enum Edge: Equatable, Sendable {
        case start
        case end
    }

    /// Resizes one edge of the visible window. Used by overview border dragging.
    func resizing(
        edge: Edge,
        to time: TimeInterval,
        sourceDuration: TimeInterval
    ) -> TimelineViewport {
        guard time.isFinite, sourceDuration.isFinite, sourceDuration > 0 else {
            return self
        }
        switch edge {
        case .start:
            let maximumStart = max(end - Self.minimumVisibleDuration, 0)
            let nextStart = min(max(time, 0), maximumStart)
            return TimelineViewport(
                start: nextStart,
                duration: end - nextStart,
                sourceDuration: sourceDuration
            )
        case .end:
            let minimumEnd = min(start + Self.minimumVisibleDuration, sourceDuration)
            let nextEnd = min(max(time, minimumEnd), sourceDuration)
            return TimelineViewport(
                start: start,
                duration: nextEnd - start,
                sourceDuration: sourceDuration
            )
        }
    }

    func contains(_ time: TimeInterval) -> Bool {
        start ... end ~= time
    }

    /// Expands the visible window just enough to keep `[requiredStart, requiredEnd]` in view.
    /// Used while recording so the overview box grows with live progress instead of clipping.
    func covering(
        start requiredStart: TimeInterval,
        end requiredEnd: TimeInterval,
        sourceDuration: TimeInterval,
        trailingPadding: TimeInterval = 0
    ) -> TimelineViewport {
        guard sourceDuration.isFinite, sourceDuration > 0 else {
            return self
        }
        let safePadding = max(trailingPadding, 0)
        let clampedStart = min(max(requiredStart, 0), sourceDuration)
        let clampedEnd = min(
            max(requiredEnd + safePadding, clampedStart),
            sourceDuration
        )
        let nextStart = min(start, clampedStart)
        let nextEnd = max(end, clampedEnd)
        return TimelineViewport(
            start: nextStart,
            duration: max(nextEnd - nextStart, Self.minimumVisibleDuration),
            sourceDuration: sourceDuration
        )
    }
}

struct WaveformEnvelopeSlice: Equatable, Sendable {
    let timelineStart: TimeInterval
    let timelineDuration: TimeInterval
    let points: [WaveformEnvelopePoint]
}

enum WaveformEnvelopeSampler {
    static func slice(
        from waveform: WaveformPresentation,
        assetTimelineStart: TimeInterval = 0,
        visibleRange: TimelineViewport,
        targetPointCount: Int
    ) -> WaveformEnvelopeSlice {
        guard targetPointCount > 0,
              waveform.duration > 0,
              waveform.sampleRate > 0,
              !waveform.levels.isEmpty
        else {
            return WaveformEnvelopeSlice(
                timelineStart: visibleRange.start,
                timelineDuration: 0,
                points: []
            )
        }

        let assetTimelineEnd = assetTimelineStart + waveform.duration
        let intersectionStart = max(visibleRange.start, assetTimelineStart)
        let intersectionEnd = min(visibleRange.end, assetTimelineEnd)
        guard intersectionEnd > intersectionStart else {
            return WaveformEnvelopeSlice(
                timelineStart: intersectionStart,
                timelineDuration: 0,
                points: []
            )
        }

        let localStart = intersectionStart - assetTimelineStart
        let localDuration = intersectionEnd - intersectionStart
        let level = selectLevel(
            waveform.levels,
            sampleRate: waveform.sampleRate,
            visibleDuration: localDuration,
            targetPointCount: targetPointCount
        )
        let startIndex = min(
            max(Int(floor(localStart * waveform.sampleRate / Double(level.framesPerPoint))), 0),
            level.points.count
        )
        let endIndex = min(
            max(
                Int(
                    ceil(
                        (localStart + localDuration) * waveform.sampleRate /
                            Double(level.framesPerPoint)
                    )
                ),
                startIndex
            ),
            level.points.count
        )
        let points = aggregate(
            Array(level.points[startIndex ..< endIndex]),
            maximumCount: targetPointCount
        )
        return WaveformEnvelopeSlice(
            timelineStart: intersectionStart,
            timelineDuration: localDuration,
            points: points
        )
    }

    static func selectLevel(
        _ levels: [WaveformEnvelopeLevel],
        sampleRate: Double,
        visibleDuration: TimeInterval,
        targetPointCount: Int
    ) -> WaveformEnvelopeLevel {
        let sorted = levels.sorted { $0.framesPerPoint < $1.framesPerPoint }
        guard let finest = sorted.first, targetPointCount > 0 else {
            return WaveformEnvelopeLevel(framesPerPoint: 1, points: [])
        }
        let targetFrames = visibleDuration * sampleRate / Double(targetPointCount)
        return sorted.last(where: { Double($0.framesPerPoint) <= targetFrames }) ?? finest
    }

    static func aggregate(
        _ points: [WaveformEnvelopePoint],
        maximumCount: Int
    ) -> [WaveformEnvelopePoint] {
        guard maximumCount > 0, points.count > maximumCount else {
            return maximumCount > 0 ? points : []
        }
        return (0 ..< maximumCount).map { index in
            let start = index * points.count / maximumCount
            let end = max((index + 1) * points.count / maximumCount, start + 1)
            let bucket = points[start ..< min(end, points.count)]
            return WaveformEnvelopePoint(
                minimum: bucket.map(\.minimum).min() ?? 0,
                maximum: bucket.map(\.maximum).max() ?? 0
            )
        }
    }
}
