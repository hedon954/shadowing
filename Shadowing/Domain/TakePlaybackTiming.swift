import Foundation

/// Timing helpers for Take-local loop selection on the shared source timeline.
enum TakePlaybackTiming: Sendable {
    /// Builds a source-timeline selection clamped inside the Take's recorded span.
    static func selectionFromDrag(
        anchor: TimeInterval,
        current: TimeInterval,
        takeRegion: PracticeRegion,
        sourceDuration: TimeInterval
    ) -> PracticeRegion? {
        let lo = takeRegion.start
        let hi = takeRegion.end
        guard hi - lo >= PracticeRegion.minimumDuration else {
            return nil
        }
        let clampedAnchor = min(max(anchor, lo), hi)
        let clampedCurrent = min(max(current, lo), hi)
        guard let draft = try? PracticeRegion.fromDrag(
            anchor: clampedAnchor,
            current: clampedCurrent,
            sourceDuration: sourceDuration
        ) else {
            return nil
        }
        return clampedSelection(draft, takeRegion: takeRegion, sourceDuration: sourceDuration)
    }

    /// Keeps an existing selection inside the Take bounds with a valid duration.
    static func clampedSelection(
        _ region: PracticeRegion,
        takeRegion: PracticeRegion,
        sourceDuration: TimeInterval
    ) -> PracticeRegion? {
        let start = max(region.start, takeRegion.start)
        let end = min(region.end, takeRegion.end)
        guard end - start >= PracticeRegion.minimumDuration else {
            return nil
        }
        return try? PracticeRegion.takeAlignment(
            id: region.id,
            start: start,
            end: end,
            sourceDuration: sourceDuration
        )
    }

    /// Maps a source-timeline Take selection into Take-local time for playback, with the
    /// take's measured offset (`RecordingAlignment.takeTime`), so the loop plays exactly what
    /// the waveform shows under the selection.
    static func localLoopRegion(
        selection: PracticeRegion,
        takeRegion: PracticeRegion,
        offset: TimeInterval = 0
    ) -> PracticeRegion? {
        let overlapStart = max(selection.start, takeRegion.start)
        let overlapEnd = min(selection.end, takeRegion.end)
        let localStart = max(
            RecordingAlignment.takeTime(forSourceTime: overlapStart, regionStart: takeRegion.start, offset: offset),
            0
        )
        let localEnd = RecordingAlignment.takeTime(
            forSourceTime: overlapEnd,
            regionStart: takeRegion.start,
            offset: offset
        )
        guard takeRegion.duration > 0,
              localEnd - localStart >= PracticeRegion.minimumDuration
        else {
            return nil
        }
        return try? PracticeRegion(
            start: localStart,
            end: localEnd,
            sourceDuration: max(takeRegion.duration, localEnd)
        )
    }
}
