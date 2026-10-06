import Foundation

extension PracticeAudioEngine {
    func handlePlaybackFinished(generation: UInt64) async {
        guard generation == scheduleGeneration else {
            return
        }
        switch playbackTarget {
        case .together:
            finishTogetherPlayback()
        case .original:
            await finishOriginalPlayback()
        case .take:
            return
        }
    }

    func handleTakePlaybackFinished(generation: UInt64) {
        guard generation == takeScheduleGeneration else {
            return
        }
        switch playbackTarget {
        case .together:
            // Original timeline owns completion; take may finish earlier.
            return
        case .take:
            isPlaying = false
            playheadTask?.cancel()
            if let takeEndFrame {
                // A Compare take segment: take-local time must never reach the main playhead.
                takePausedFrame = takeEndFrame
                eventHub.yield(.segmentFinished)
            } else {
                if let takeInfo {
                    takePausedFrame = takeInfo.frameCount
                    eventHub.yield(.playheadChanged(takeInfo.duration))
                }
                eventHub.yield(.playbackFinished)
            }
            takeEndFrame = nil
            // Return to the original timeline so later seeks use source time,
            // not take-local time (and so paused seekTake does not re-fire completion).
            takeScheduleGeneration &+= 1
            takePlayer.stop()
            takeLoopRegion = nil
            takeFirstScheduledFrameCount = 0
            playbackTarget = .original
        case .original:
            return
        }
    }

    private func finishTogetherPlayback() {
        stopTakeNode()
        isPlaying = false
        playheadTask?.cancel()
        let endFrame = scheduledStartFrame + firstScheduledFrameCount
        pausedFrame = endFrame
        playbackTarget = .original
        if let sourceInfo, sourceInfo.sampleRate > 0 {
            eventHub.yield(
                .playheadChanged(Double(endFrame) / sourceInfo.sampleRate)
            )
        }
        eventHub.yield(.playbackFinished)
    }

    private func finishOriginalPlayback() async {
        isPlaying = false
        playheadTask?.cancel()
        if recordingContext != nil {
            do {
                try await finishRecording(reason: .regionEnd)
            } catch {
                eventHub.yield(
                    .failed(
                        PracticeAudioFailure(
                            operation: .recording,
                            message: error.localizedDescription
                        )
                    )
                )
            }
            return
        }
        if let segmentEnd = originalSegmentEndFrame {
            // A one-shot segment ended inside the track: stay at its end, not the track's end.
            originalSegmentEndFrame = nil
            pausedFrame = segmentEnd
            if let sourceInfo, sourceInfo.sampleRate > 0 {
                eventHub.yield(.playheadChanged(Double(segmentEnd) / sourceInfo.sampleRate))
            }
            eventHub.yield(.segmentFinished)
            return
        }
        if let sourceInfo {
            pausedFrame = sourceInfo.frameCount
            eventHub.yield(.playheadChanged(sourceInfo.duration))
        }
        eventHub.yield(.playbackFinished)
    }
}
