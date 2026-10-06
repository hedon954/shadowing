@preconcurrency import AVFoundation
import Foundation

extension PracticeAudioEngine {
    func schedulePlayback(
        from sourceFrame: Int64,
        forcedEndFrame: Int64? = nil
    ) throws {
        guard let sourceFile, let sourceInfo else {
            throw PracticeAudioEngineError.sourceNotLoaded
        }
        scheduleGeneration &+= 1
        let generation = scheduleGeneration
        player.stop()

        let plan: PlaybackSegmentPlan
        if let forcedEndFrame {
            guard sourceFrame >= 0,
                  forcedEndFrame > sourceFrame,
                  forcedEndFrame <= sourceInfo.frameCount
            else {
                throw AudioTimingError.invalidFrameRange
            }
            plan = PlaybackSegmentPlan(
                initial: AudioSegment(
                    startFrame: sourceFrame,
                    frameCount: forcedEndFrame - sourceFrame
                ),
                repeated: nil
            )
        } else {
            plan = try PlaybackSegmentPlanner.plan(
                from: sourceFrame,
                sourceFrameCount: sourceInfo.frameCount,
                loopScheduler: makeLoopScheduler()
            )
        }
        scheduledStartFrame = plan.initial.startFrame
        firstScheduledFrameCount = plan.initial.frameCount
        scheduledLoops = plan.repeated != nil
        originalSegmentEndFrame = forcedEndFrame
        try scheduleSegment(
            file: sourceFile,
            startFrame: plan.initial.startFrame,
            frameCount: plan.initial.frameCount,
            generation: plan.repeated == nil ? generation : nil
        )

        if let repeated = plan.repeated {
            try enqueueLoopingSegment(
                on: player,
                file: sourceFile,
                segment: repeated,
                loopGeneration: generation,
                isTake: false
            )
        }
        pausedFrame = plan.initial.startFrame
    }

    private func scheduleSegment(
        file: AVAudioFile,
        startFrame: Int64,
        frameCount: Int64,
        generation: UInt64?
    ) throws {
        guard frameCount > 0, frameCount <= Int64(UInt32.max) else {
            throw PracticeAudioEngineError.frameCountTooLarge
        }
        player.scheduleSegment(
            file,
            startingFrame: startFrame,
            frameCount: AVAudioFrameCount(frameCount),
            at: nil,
            completionCallbackType: segmentCallbackType,
            completionHandler: { [weak self] _ in
                guard let generation else {
                    return
                }
                Self.hop(self) { await $0.handlePlaybackFinished(generation: generation) }
            }
        )
    }

    /// File-based looping; requeue via actor state (no `AVAudioFile` in `@Sendable` handlers).
    func enqueueLoopingSegment(
        on node: AVAudioPlayerNode,
        file: AVAudioFile,
        segment: AudioSegment,
        loopGeneration: UInt64,
        isTake: Bool
    ) throws {
        guard segment.frameCount > 0, segment.frameCount <= Int64(UInt32.max) else {
            throw PracticeAudioEngineError.frameCountTooLarge
        }
        node.scheduleSegment(
            file,
            startingFrame: segment.startFrame,
            frameCount: AVAudioFrameCount(segment.frameCount),
            at: nil,
            completionCallbackType: segmentCallbackType,
            completionHandler: { [weak self] _ in
                Self.hop(self) {
                    await $0.requeueLoopingSegment(
                        segment: segment,
                        loopGeneration: loopGeneration,
                        isTake: isTake
                    )
                }
            }
        )
    }

    private func requeueLoopingSegment(
        segment: AudioSegment,
        loopGeneration: UInt64,
        isTake: Bool
    ) {
        if isTake {
            guard let takeFile,
                  loopGeneration == takeScheduleGeneration,
                  isPlaying,
                  playbackTarget == .take
            else {
                return
            }
            takePlayer.scheduleSegment(
                takeFile,
                startingFrame: segment.startFrame,
                frameCount: AVAudioFrameCount(segment.frameCount),
                at: nil,
                completionCallbackType: segmentCallbackType,
                completionHandler: { [weak self] _ in
                    Self.hop(self) {
                        await $0.requeueLoopingSegment(
                            segment: segment,
                            loopGeneration: loopGeneration,
                            isTake: true
                        )
                    }
                }
            )
            return
        }
        guard let sourceFile,
              loopGeneration == scheduleGeneration,
              isPlaying,
              playbackTarget == .original
        else {
            return
        }
        player.scheduleSegment(
            sourceFile,
            startingFrame: segment.startFrame,
            frameCount: AVAudioFrameCount(segment.frameCount),
            at: nil,
            completionCallbackType: segmentCallbackType,
            completionHandler: { [weak self] _ in
                Self.hop(self) {
                    await $0.requeueLoopingSegment(
                        segment: segment,
                        loopGeneration: loopGeneration,
                        isTake: false
                    )
                }
            }
        )
    }

    func play(from position: TimeInterval? = nil) throws {
        guard sourceFile != nil, let sourceInfo else {
            throw PracticeAudioEngineError.sourceNotLoaded
        }
        stopTakeNode()
        playbackTarget = .original
        let converter = try AudioFrameTimeConverter(sampleRate: sourceInfo.sampleRate)
        let requestedFrame = try position.map(converter.frame(at:)) ?? pausedFrame
        let frame = try normalizedPlaybackFrame(requestedFrame)
        try schedulePlayback(from: frame)
        try ensureEngineRunning()
        player.play()
        isPlaying = true
        startPlayheadUpdates()
    }

    func playRegionOnce(_ region: PracticeRegion, from position: TimeInterval) throws {
        guard sourceFile != nil, let sourceInfo else {
            throw PracticeAudioEngineError.sourceNotLoaded
        }
        stopTakeNode()
        playbackTarget = .original
        let converter = try AudioFrameTimeConverter(sampleRate: sourceInfo.sampleRate)
        let start = max(position, region.start)
        let startFrame = try converter.frame(at: start)
        let endFrame = try converter.frame(at: region.end)
        try schedulePlayback(from: startFrame, forcedEndFrame: endFrame)
        try ensureEngineRunning()
        player.play()
        isPlaying = true
        startPlayheadUpdates()
    }

    func pause() {
        guard isPlaying else {
            return
        }
        switch playbackTarget {
        case .take:
            takePausedFrame = currentTakeFrame()
            takeScheduleGeneration &+= 1
            takePlayer.stop()
            takeLoopRegion = nil
            takeFirstScheduledFrameCount = 0
            takeFile = nil
            takeInfo = nil
            playbackTarget = .original
            isPlaying = false
            playheadTask?.cancel()
            // Keep ViewModel source playhead; do not publish take-local time.
            return
        case .together:
            takePausedFrame = currentTakeFrame()
            pausedFrame = currentSourceFrame()
            takePlayer.pause()
            player.pause()
        case .original:
            pausedFrame = currentSourceFrame()
            player.pause()
        }
        isPlaying = false
        playheadTask?.cancel()
        publishPlayhead()
    }

    func seek(to position: TimeInterval) throws {
        guard position.isFinite, position >= 0 else {
            throw PracticeAudioEngineError.invalidSeekTime(position)
        }
        if playbackTarget == .take {
            takeScheduleGeneration &+= 1
            takePlayer.stop()
            isPlaying = false
            playheadTask?.cancel()
            takeLoopRegion = nil
            takeFirstScheduledFrameCount = 0
            playbackTarget = .original
        }
        if playbackTarget == .together {
            pause()
            return
        }
        guard let sourceInfo else {
            throw PracticeAudioEngineError.invalidSeekTime(position)
        }
        let converter = try AudioFrameTimeConverter(sampleRate: sourceInfo.sampleRate)
        let frame = try normalizedPlaybackFrame(converter.frame(at: position))
        let shouldResume = isPlaying
        player.stop()
        isPlaying = false
        pausedFrame = frame
        try schedulePlayback(from: frame)
        if shouldResume {
            try ensureEngineRunning()
            player.play()
            isPlaying = true
            startPlayheadUpdates()
        }
        publishPlayhead()
    }

    func setRate(_ rate: Double) throws {
        guard rate.isFinite, 0.5 ... 1.5 ~= rate else {
            throw PracticeAudioEngineError.invalidPlaybackRate(rate)
        }
        guard playbackRate != rate else {
            return
        }
        let shouldResume = isPlaying && playbackTarget == .original
        let frame = currentSourceFrame()
        playbackRate = rate
        timePitch.rate = Float(rate)
        if sourceFile != nil, playbackTarget == .original {
            player.stop()
            isPlaying = false
            pausedFrame = frame
            try schedulePlayback(from: normalizedPlaybackFrame(frame))
            if shouldResume {
                try ensureEngineRunning()
                player.play()
                isPlaying = true
                startPlayheadUpdates()
            }
        }
    }

    func setVolume(_ volume: Float) throws {
        guard volume.isFinite, 0 ... 1 ~= volume else {
            throw PracticeAudioEngineError.invalidVolume(volume)
        }
        player.volume = volume
        takePlayer.volume = volume
    }

    func setLoop(_ region: PracticeRegion?) throws {
        if let region, let sourceInfo {
            let converter = try AudioFrameTimeConverter(sampleRate: sourceInfo.sampleRate)
            _ = try RegionLoopScheduler(
                region: region,
                converter: converter,
                playbackRate: playbackRate
            )
            guard region.end <= sourceInfo.duration else {
                throw PracticeAudioEngineError.invalidSeekTime(region.end)
            }
        }

        let shouldResume = isPlaying && playbackTarget == .original
        let currentFrame = currentSourceFrame()
        loopRegion = region
        guard sourceFile != nil, playbackTarget == .original else {
            return
        }
        player.stop()
        isPlaying = false
        let frame = try normalizedPlaybackFrame(currentFrame)
        pausedFrame = frame
        try schedulePlayback(from: frame)
        if shouldResume {
            try ensureEngineRunning()
            player.play()
            isPlaying = true
            startPlayheadUpdates()
        }
    }
}
