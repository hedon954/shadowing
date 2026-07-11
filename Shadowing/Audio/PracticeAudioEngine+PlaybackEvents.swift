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
            if let takeInfo {
                takePausedFrame = takeInfo.frameCount
                eventContinuation.yield(.playheadChanged(takeInfo.duration))
            }
            eventContinuation.yield(.playbackFinished)
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
            eventContinuation.yield(
                .playheadChanged(Double(endFrame) / sourceInfo.sampleRate)
            )
        }
        eventContinuation.yield(.playbackFinished)
    }

    private func finishOriginalPlayback() async {
        isPlaying = false
        playheadTask?.cancel()
        if recordingContext != nil {
            do {
                try await finishRecording(reason: .regionEnd)
            } catch {
                eventContinuation.yield(
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
        if let sourceInfo {
            pausedFrame = sourceInfo.frameCount
            eventContinuation.yield(.playheadChanged(sourceInfo.duration))
        }
        eventContinuation.yield(.playbackFinished)
    }
}
