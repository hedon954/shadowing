import Foundation

extension PracticeViewModel {
    var recordingTimelineRegion: PracticeRegion? {
        recordingWindow ?? recordingContext?.region
    }

    /// Highlight from the Original cursor through current progress only.
    var recordingDisplayRegion: PracticeRegion? {
        guard let window = recordingTimelineRegion else {
            return nil
        }
        let end = min(
            max(playhead, window.start + PracticeRegion.minimumDuration),
            window.end
        )
        return try? PracticeRegion.takeAlignment(
            id: window.id,
            start: window.start,
            end: end,
            sourceDuration: project.duration
        )
    }

    var originalRecordingRegionPeaks: [Float] {
        guard let region = recordingTimelineRegion ?? region,
              project.duration > 0,
              !waveform.peaks.isEmpty
        else {
            return []
        }
        let startIndex = min(
            max(Int(region.start / project.duration * Double(waveform.peaks.count)), 0),
            waveform.peaks.count - 1
        )
        let endIndex = min(
            max(
                Int(ceil(region.end / project.duration * Double(waveform.peaks.count))),
                startIndex + 1
            ),
            waveform.peaks.count
        )
        return Array(waveform.peaks[startIndex ..< endIndex])
    }

    var recordingProgressFraction: Double {
        guard let region = recordingTimelineRegion, region.duration > 0 else {
            return 0
        }
        switch recordingPresentation {
        case let .recording(elapsed):
            let expectedDuration = region.duration / recordingTimelineRate
            return min(max(elapsed / expectedDuration, 0), 1)
        case .finalizing:
            return 1
        case .idle, .checkingPermission, .countingDown:
            return 0
        }
    }

    var recordingElapsed: TimeInterval {
        if case let .recording(elapsed) = recordingPresentation {
            return elapsed
        }
        return activeTake?.duration ?? 0
    }

    var timelinePlayhead: TimeInterval {
        playhead
    }

    var liveRecordingTimelineEnvelope: [TimedWaveformEnvelopePoint] {
        guard let region = recordingTimelineRegion else {
            return []
        }
        return liveRecordingEnvelope.map { point in
            TimedWaveformEnvelopePoint(
                time: region.start + point.time * recordingTimelineRate,
                envelope: point.envelope
            )
        }
    }

    func seekTimeline(_ sourceTime: TimeInterval) {
        pauseTakePlaybackIfNeeded()
        seek(to: sourceTime)
    }

    /// Moves the overview window onto a Take (or its loop selection) when it is off-screen.
    func focusTimelineForTakePlayback(_ take: Take) {
        let focus = takeLoopSelections[take.id] ?? take.region
        let overlapStart = max(focus.start, timelineViewport.start)
        let overlapEnd = min(focus.end, timelineViewport.end)
        let meaningfulOverlap = overlapEnd > overlapStart
            && (overlapEnd - overlapStart) >= min(0.25, focus.duration * 0.2)
        if !meaningfulOverlap {
            timelineViewport = .fitting(focus, sourceDuration: project.duration)
            return
        }
        followPlayheadInTimeline(at: playhead)
    }

    func setTimelineGestureActive(_ active: Bool) {
        guard suspendPlayheadFollow != active else {
            return
        }
        suspendPlayheadFollow = active
    }

    /// Pans the viewport so the playhead stays visible during playback.
    func followPlayheadInTimeline(at position: TimeInterval) {
        guard !suspendPlayheadFollow,
              timelineViewport.duration > 0,
              !timelineViewport.contains(position)
        else {
            return
        }
        let visibleDuration = timelineViewport.duration
        timelineViewport = TimelineViewport(
            start: position - visibleDuration * 0.2,
            duration: visibleDuration,
            sourceDuration: project.duration
        )
    }

    func showFullTimeline() {
        guard !controlsLocked else {
            return
        }
        timelineViewport = .full(sourceDuration: project.duration)
    }

    func fitTimelineToRegion() {
        guard let region else {
            showFullTimeline()
            return
        }
        timelineViewport = .fitting(
            region,
            sourceDuration: project.duration
        )
    }

    func zoomTimeline(by factor: Double, anchor: TimeInterval) {
        guard !controlsLocked else {
            return
        }
        timelineViewport = timelineViewport.zoomed(
            by: factor,
            anchor: anchor,
            sourceDuration: project.duration
        )
    }

    func setTimelineViewport(_ viewport: TimelineViewport) {
        guard !controlsLocked else {
            return
        }
        let normalized = TimelineViewport(
            start: viewport.start,
            duration: viewport.duration,
            sourceDuration: project.duration
        )
        guard normalized != timelineViewport else {
            return
        }
        timelineViewport = normalized
    }

    func ensurePlayheadVisibleForRecording(at position: TimeInterval) {
        guard !timelineViewport.contains(position) else {
            return
        }
        let visibleDuration = max(min(timelineViewport.duration, 30), 8)
        timelineViewport = TimelineViewport(
            start: position - visibleDuration * 0.2,
            duration: visibleDuration,
            sourceDuration: project.duration
        )
    }

    /// Grows the overview window so recording start → current playhead stays visible.
    func revealRecordingProgress(at position: TimeInterval) {
        let recordingStart = recordingTimelineRegion?.start ?? position
        let trailingPadding = max(min(timelineViewport.duration * 0.08, 1.5), 0.25)
        let expanded = timelineViewport.covering(
            start: recordingStart,
            end: position,
            sourceDuration: project.duration,
            trailingPadding: trailingPadding
        )
        guard expanded != timelineViewport else {
            return
        }
        timelineViewport = expanded
    }
}
