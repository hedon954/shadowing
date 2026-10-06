@preconcurrency import AVFoundation
import Foundation

/// Take playback (alone, or together with the original while recording). It uses the same
/// segment planner as the original, so a take loop never moves the playhead either: starting
/// before the take's loop plays into it and loops; at or after its end plays on to the take's end.
extension PracticeAudioEngine {
    func playTake(url: URL, from position: TimeInterval, loop: PracticeRegion?, end: TimeInterval? = nil) throws {
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
        takeLoopRegion = loop
        playbackTarget = .take

        let converter = try AudioFrameTimeConverter(sampleRate: sampleRate)
        takeEndFrame = try end.map { try min(converter.frame(at: $0), frameCount) }
        if let loop {
            _ = try RegionLoopScheduler(
                region: loop,
                converter: converter,
                playbackRate: playbackRate
            )
            guard loop.end <= info.duration + 0.001 else {
                throw PracticeAudioEngineError.invalidSeekTime(loop.end)
            }
        }
        let requestedFrame = try converter.frame(at: max(position, 0))
        let frame = min(max(requestedFrame, 0), max(frameCount - 1, 0))
        try scheduleTakePlayback(from: frame)
        try ensureEngineRunning()
        takePlayer.play()
        isPlaying = true
        startPlayheadUpdates()
    }

    func playTogether(region: PracticeRegion, takeURL: URL, rate: Double) throws {
        guard sourceFile != nil, let sourceInfo else {
            throw PracticeAudioEngineError.sourceNotLoaded
        }

        let file: AVAudioFile
        do {
            file = try AVAudioFile(forReading: takeURL)
        } catch {
            throw PracticeAudioEngineError.audioEngineFailed(error.localizedDescription)
        }
        let sampleRate = file.processingFormat.sampleRate
        let frameCount = file.length
        takeFile = file
        takeInfo = LoadedAudioSource(
            duration: Double(frameCount) / sampleRate,
            sampleRate: sampleRate,
            frameCount: frameCount
        )
        takeLoopRegion = nil
        takeEndFrame = nil

        try setLoop(nil)
        try setRate(rate)
        playbackTarget = .together

        let converter = try AudioFrameTimeConverter(sampleRate: sourceInfo.sampleRate)
        let startFrame = try converter.frame(at: region.start)
        let endFrame = try converter.frame(at: region.end)
        try schedulePlayback(from: startFrame, forcedEndFrame: endFrame)
        try scheduleTakePlayback(from: 0)
        try ensureEngineRunning()
        player.play()
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

        let plan: PlaybackSegmentPlan
        if let takeLoopRegion {
            let converter = try AudioFrameTimeConverter(sampleRate: takeInfo.sampleRate)
            let scheduler = try RegionLoopScheduler(
                region: takeLoopRegion,
                converter: converter,
                playbackRate: playbackRate
            )
            guard scheduler.regionEndFrame <= takeInfo.frameCount else {
                throw AudioTimingError.invalidFrameRange
            }
            plan = try PlaybackSegmentPlanner.plan(
                from: sourceFrame,
                sourceFrameCount: takeInfo.frameCount,
                loopScheduler: scheduler
            )
        } else {
            plan = try PlaybackSegmentPlanner.plan(
                from: sourceFrame,
                sourceFrameCount: takeEndFrame ?? takeInfo.frameCount,
                loopScheduler: nil
            )
        }

        takeScheduledStartFrame = plan.initial.startFrame
        takeFirstScheduledFrameCount = plan.initial.frameCount
        takeScheduledLoops = plan.repeated != nil
        takePausedFrame = plan.initial.startFrame
        try scheduleTakeSegment(
            file: takeFile,
            startFrame: plan.initial.startFrame,
            frameCount: plan.initial.frameCount,
            generation: plan.repeated == nil ? generation : nil
        )
        if let repeated = plan.repeated {
            try enqueueLoopingSegment(
                on: takePlayer,
                file: takeFile,
                segment: repeated,
                loopGeneration: generation,
                isTake: true
            )
        }
    }

    private func scheduleTakeSegment(
        file: AVAudioFile,
        startFrame: Int64,
        frameCount: Int64,
        generation: UInt64?
    ) throws {
        guard frameCount > 0, frameCount <= Int64(UInt32.max) else {
            throw PracticeAudioEngineError.frameCountTooLarge
        }
        takePlayer.scheduleSegment(
            file,
            startingFrame: startFrame,
            frameCount: AVAudioFrameCount(frameCount),
            at: nil,
            completionCallbackType: segmentCallbackType,
            completionHandler: { [weak self] _ in
                guard let generation else {
                    return
                }
                Self.hop(self) { await $0.handleTakePlaybackFinished(generation: generation) }
            }
        )
    }
}
