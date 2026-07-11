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
        try scheduleSegment(
            file: sourceFile,
            startFrame: plan.initial.startFrame,
            frameCount: plan.initial.frameCount,
            options: .interrupts,
            generation: plan.repeated == nil ? generation : nil
        )

        if let repeated = plan.repeated {
            try scheduleSegment(
                file: sourceFile,
                startFrame: repeated.startFrame,
                frameCount: repeated.frameCount,
                options: .loops,
                generation: nil
            )
        }
        pausedFrame = plan.initial.startFrame
    }

    private func scheduleSegment(
        file: AVAudioFile,
        startFrame: Int64,
        frameCount: Int64,
        options: AVAudioPlayerNodeBufferOptions,
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
            completionCallbackType: .dataPlayedBack,
            completionHandler: { [weak self] _ in
                guard let generation else {
                    return
                }
                Task {
                    await self?.handlePlaybackFinished(generation: generation)
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

    func playTake(url: URL, from position: TimeInterval) throws {
        guard sourceFile != nil else {
            throw PracticeAudioEngineError.sourceNotLoaded
        }
        scheduleGeneration &+= 1
        player.stop()
        isPlaying = false
        playheadTask?.cancel()

        let file: AVAudioFile
        do {
            file = try AVAudioFile(forReading: url)
        } catch {
            throw PracticeAudioEngineError.audioEngineFailed(error.localizedDescription)
        }
        let sampleRate = file.processingFormat.sampleRate
        let frameCount = file.length
        let info = LoadedAudioSource(
            duration: Double(frameCount) / sampleRate,
            sampleRate: sampleRate,
            frameCount: frameCount
        )
        takeFile = file
        takeInfo = info
        playbackTarget = .take

        let converter = try AudioFrameTimeConverter(sampleRate: sampleRate)
        let requestedFrame = try converter.frame(at: max(position, 0))
        let frame = min(max(requestedFrame, 0), max(frameCount - 1, 0))
        try scheduleTakePlayback(from: frame)
        try ensureEngineRunning()
        takePlayer.play()
        isPlaying = true
        startPlayheadUpdates()
    }

    private func scheduleTakePlayback(from sourceFrame: Int64) throws {
        guard let takeFile, let takeInfo else {
            throw PracticeAudioEngineError.sourceNotLoaded
        }
        takeScheduleGeneration &+= 1
        let generation = takeScheduleGeneration
        takePlayer.stop()

        let frameCount = takeInfo.frameCount - sourceFrame
        guard frameCount > 0, frameCount <= Int64(UInt32.max) else {
            throw PracticeAudioEngineError.frameCountTooLarge
        }
        takeScheduledStartFrame = sourceFrame
        takePausedFrame = sourceFrame
        takePlayer.scheduleSegment(
            takeFile,
            startingFrame: sourceFrame,
            frameCount: AVAudioFrameCount(frameCount),
            at: nil,
            completionCallbackType: .dataPlayedBack,
            completionHandler: { [weak self] _ in
                Task {
                    await self?.handleTakePlaybackFinished(generation: generation)
                }
            }
        )
    }

    private func stopTakeNode() {
        takeScheduleGeneration &+= 1
        takePlayer.stop()
    }

    func pause() {
        guard isPlaying else {
            return
        }
        if playbackTarget == .take {
            takePausedFrame = currentTakeFrame()
            takePlayer.pause()
        } else {
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
            try seekTake(to: position)
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

    private func seekTake(to position: TimeInterval) throws {
        guard let takeInfo else {
            throw PracticeAudioEngineError.sourceNotLoaded
        }
        let converter = try AudioFrameTimeConverter(sampleRate: takeInfo.sampleRate)
        let requestedFrame = try converter.frame(at: position)
        let frame = min(max(requestedFrame, 0), max(takeInfo.frameCount - 1, 0))
        let shouldResume = isPlaying
        takePlayer.stop()
        isPlaying = false
        takePausedFrame = frame
        try scheduleTakePlayback(from: frame)
        if shouldResume {
            try ensureEngineRunning()
            takePlayer.play()
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
