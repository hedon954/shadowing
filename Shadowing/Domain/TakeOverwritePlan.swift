import Foundation

/// One contiguous piece of a merged take file on the source timeline.
struct TakeOverwriteSegment: Equatable, Sendable {
    enum Source: Equatable, Sendable {
        /// Keep audio from the previous take file.
        case previous(localStart: TimeInterval)
        /// Insert audio from the new recording.
        case incoming(localStart: TimeInterval)
        /// Pad with silence so the take stays aligned to Original time.
        case silence
    }

    let duration: TimeInterval
    let source: Source
}

/// Plans how a new recording merges with an existing take on the source timeline.
///
/// The merged file is a continuous CAF whose local t=0 maps to `resultStart` on the
/// Original timeline. Gaps between non-overlapping recordings are filled with silence
/// so waveforms and playback stay synchronized with Original.
struct TakeOverwritePlan: Equatable, Sendable {
    /// Source-timeline start of the resulting take.
    let resultStart: TimeInterval
    /// Total duration of the resulting take file (includes silence gaps).
    let resultDuration: TimeInterval
    /// Ordered pieces that recreate the take file from previous / incoming / silence.
    let segments: [TakeOverwriteSegment]

    /// Builds a merge plan that overwrites only the overlapping source range and
    /// preserves Original alignment with silence between non-overlapping ranges.
    static func planning(
        previousStart: TimeInterval,
        previousDuration: TimeInterval,
        newStart: TimeInterval,
        newDuration: TimeInterval
    ) -> TakeOverwritePlan {
        let previousEnd = previousStart + max(previousDuration, 0)
        let newEnd = newStart + max(newDuration, 0)
        let resultStart = min(previousStart, newStart)
        let resultEnd = max(previousEnd, newEnd)
        let resultDuration = max(resultEnd - resultStart, 0)

        var cuts: Set<TimeInterval> = [resultStart, resultEnd]
        if previousDuration > 0 {
            cuts.insert(previousStart)
            cuts.insert(previousEnd)
        }
        if newDuration > 0 {
            cuts.insert(newStart)
            cuts.insert(newEnd)
        }
        let ordered = cuts
            .filter { $0 >= resultStart - 0.000_000_1 && $0 <= resultEnd + 0.000_000_1 }
            .sorted()

        var segments: [TakeOverwriteSegment] = []
        for index in 0 ..< max(ordered.count - 1, 0) {
            let start = ordered[index]
            let end = ordered[index + 1]
            let duration = end - start
            guard duration > 0.000_000_1 else {
                continue
            }
            let midpoint = start + duration / 2
            let source: TakeOverwriteSegment.Source = if midpoint >= newStart, midpoint < newEnd {
                .incoming(localStart: start - newStart)
            } else if midpoint >= previousStart, midpoint < previousEnd {
                .previous(localStart: start - previousStart)
            } else {
                .silence
            }
            if let last = segments.last, Self.canCoalesce(last, with: source) {
                segments[segments.count - 1] = TakeOverwriteSegment(
                    duration: last.duration + duration,
                    source: last.source
                )
            } else {
                segments.append(TakeOverwriteSegment(duration: duration, source: source))
            }
        }

        return TakeOverwritePlan(
            resultStart: resultStart,
            resultDuration: resultDuration,
            segments: segments
        )
    }

    /// True when the new recording alone is not already the full result file.
    var needsSplice: Bool {
        guard segments.count == 1,
              case let .incoming(localStart) = segments[0].source,
              abs(localStart) < 0.000_000_1,
              abs(segments[0].duration - resultDuration) < 0.000_000_1
        else {
            return true
        }
        return false
    }

    /// Convenience for tests / callers that still reason about head / insert / tail.
    var headDuration: TimeInterval {
        guard case .previous = segments.first?.source else {
            return 0
        }
        return segments.first?.duration ?? 0
    }

    var insertedDuration: TimeInterval {
        segments.reduce(0) { partial, segment in
            if case .incoming = segment.source {
                return partial + segment.duration
            }
            return partial
        }
    }

    var tailDuration: TimeInterval {
        guard case .previous = segments.last?.source, segments.count > 1 else {
            return 0
        }
        return segments.last?.duration ?? 0
    }

    var previousTailLocalStart: TimeInterval {
        guard case let .previous(localStart) = segments.last?.source, segments.count > 1 else {
            return 0
        }
        return localStart
    }

    var silenceDuration: TimeInterval {
        segments.reduce(0) { partial, segment in
            if case .silence = segment.source {
                return partial + segment.duration
            }
            return partial
        }
    }

    private static func canCoalesce(
        _ last: TakeOverwriteSegment,
        with next: TakeOverwriteSegment.Source
    ) -> Bool {
        switch (last.source, next) {
        case (.silence, .silence):
            true
        case let (.previous(previousLocal), .previous(nextLocal)):
            abs(previousLocal + last.duration - nextLocal) < 0.000_000_1
        case let (.incoming(previousLocal), .incoming(nextLocal)):
            abs(previousLocal + last.duration - nextLocal) < 0.000_000_1
        default:
            false
        }
    }
}
