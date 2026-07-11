import Foundation

/// Plans how a new recording merges with an existing take on the source timeline.
struct TakeOverwritePlan: Equatable, Sendable {
    /// Source-timeline start of the resulting take.
    let resultStart: TimeInterval
    /// Total duration of the resulting take file.
    let resultDuration: TimeInterval
    /// Seconds of the previous take to keep before the new recording.
    let headDuration: TimeInterval
    /// Duration of the new recording to insert.
    let insertedDuration: TimeInterval
    /// Seconds of the previous take to keep after the new recording.
    let tailDuration: TimeInterval
    /// Local offset into the previous take file where the tail begins.
    let previousTailLocalStart: TimeInterval

    /// Builds a merge plan that overwrites only the overlapping source range.
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

        let headDuration = max(0, min(newStart, previousEnd) - previousStart)
        let insertedDuration = max(newDuration, 0)
        let tailStart = max(newEnd, previousStart)
        let tailDuration = max(0, previousEnd - tailStart)
        let previousTailLocalStart = max(0, tailStart - previousStart)

        return TakeOverwritePlan(
            resultStart: resultStart,
            resultDuration: resultDuration,
            headDuration: headDuration,
            insertedDuration: insertedDuration,
            tailDuration: tailDuration,
            previousTailLocalStart: previousTailLocalStart
        )
    }

    var needsSplice: Bool {
        headDuration > 0 || tailDuration > 0
    }
}
