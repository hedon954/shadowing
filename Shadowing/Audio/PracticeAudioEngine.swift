@preconcurrency import AppKit
@preconcurrency import AVFoundation
import Foundation

enum PracticePlaybackTarget: Equatable, Sendable {
    case original
    case take
}

actor PracticeAudioEngine: PracticeAudioClient {
    typealias TakeURLResolver = @Sendable (UUID) async throws -> URL

    let engine = AVAudioEngine()
    let player = AVAudioPlayerNode()
    let takePlayer = AVAudioPlayerNode()
    let timePitch = AVAudioUnitTimePitch()
    let takeURLResolver: TakeURLResolver?
    private let events: AsyncStream<PracticeAudioEvent>
    let eventContinuation: AsyncStream<PracticeAudioEvent>.Continuation

    var sourceFile: AVAudioFile?
    var sourceInfo: LoadedAudioSource?
    var originalSourceURL: URL?
    var takeFile: AVAudioFile?
    var takeInfo: LoadedAudioSource?
    var playbackTarget: PracticePlaybackTarget = .original
    var playbackRate: Double = 1
    var loopRegion: PracticeRegion?
    var scheduledStartFrame: Int64 = 0
    var firstScheduledFrameCount: Int64 = 0
    var scheduleGeneration: UInt64 = 0
    var takeScheduleGeneration: UInt64 = 0
    var isPlaying = false
    var pausedFrame: Int64 = 0
    var takePausedFrame: Int64 = 0
    var takeScheduledStartFrame: Int64 = 0
    var playheadTask: Task<Void, Never>?
    var recordingContext: RecordingContext?
    var recordingPeakTask: Task<Void, Never>?
    /// NotificationCenter tokens are only mutated during initialization and deinitialization.
    private nonisolated(unsafe) var notificationTokens: [NSObjectProtocol] = []
    private nonisolated(unsafe) var workspaceNotificationTokens: [NSObjectProtocol] = []

    init(takeURLResolver: TakeURLResolver? = nil) {
        self.takeURLResolver = takeURLResolver
        let pair = AsyncStream<PracticeAudioEvent>.makeStream(
            bufferingPolicy: .bufferingNewest(256)
        )
        events = pair.stream
        eventContinuation = pair.continuation

        engine.attach(player)
        engine.attach(takePlayer)
        engine.attach(timePitch)
        engine.connect(player, to: timePitch, format: nil)
        engine.connect(timePitch, to: engine.mainMixerNode, format: nil)
        engine.connect(takePlayer, to: engine.mainMixerNode, format: nil)

        let token = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: nil
        ) { [weak self] _ in
            Task {
                await self?.handleEngineConfigurationChange()
            }
        }
        notificationTokens.append(token)

        let workspaceCenter = NSWorkspace.shared.notificationCenter
        let sleepToken = workspaceCenter.addObserver(
            forName: NSWorkspace.willSleepNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            Task {
                await self?.handleSystemInterruption()
            }
        }
        workspaceNotificationTokens.append(sleepToken)
    }

    deinit {
        playheadTask?.cancel()
        recordingPeakTask?.cancel()
        eventContinuation.finish()
        for token in notificationTokens {
            NotificationCenter.default.removeObserver(token)
        }
        for token in workspaceNotificationTokens {
            NSWorkspace.shared.notificationCenter.removeObserver(token)
        }
    }

    func eventStream() async -> AsyncStream<PracticeAudioEvent> {
        events
    }

    func ensureEngineRunning() throws {
        guard !engine.isRunning else {
            return
        }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            throw PracticeAudioEngineError.audioEngineFailed(error.localizedDescription)
        }
    }

    func normalizedPlaybackFrame(_ requestedFrame: Int64) throws -> Int64 {
        guard let sourceInfo else {
            throw PracticeAudioEngineError.sourceNotLoaded
        }
        if let scheduler = try makeLoopScheduler() {
            return scheduler.contains(requestedFrame)
                ? requestedFrame
                : scheduler.regionStartFrame
        }
        return min(max(requestedFrame, 0), max(sourceInfo.frameCount - 1, 0))
    }

    func currentSourceFrame() -> Int64 {
        guard isPlaying,
              playbackTarget == .original,
              let renderTime = player.lastRenderTime,
              let playerTime = player.playerTime(forNodeTime: renderTime)
        else {
            return pausedFrame
        }
        let elapsedFrames = max(Int64(playerTime.sampleTime), 0)
        guard let loopRegion, let sourceInfo else {
            return min(scheduledStartFrame + elapsedFrames, sourceInfo?.frameCount ?? 0)
        }
        let loopStart = Int64(
            (loopRegion.start * sourceInfo.sampleRate).rounded(.toNearestOrAwayFromZero)
        )
        let loopEnd = Int64(
            (loopRegion.end * sourceInfo.sampleRate).rounded(.toNearestOrAwayFromZero)
        )
        if elapsedFrames < firstScheduledFrameCount {
            return min(scheduledStartFrame + elapsedFrames, loopEnd - 1)
        }
        let loopFrameCount = loopEnd - loopStart
        return loopStart + (elapsedFrames - firstScheduledFrameCount) % loopFrameCount
    }

    func currentTakeFrame() -> Int64 {
        guard isPlaying,
              playbackTarget == .take,
              let renderTime = takePlayer.lastRenderTime,
              let playerTime = takePlayer.playerTime(forNodeTime: renderTime)
        else {
            return takePausedFrame
        }
        let elapsedFrames = max(Int64(playerTime.sampleTime), 0)
        return min(
            takeScheduledStartFrame + elapsedFrames,
            takeInfo?.frameCount ?? takeScheduledStartFrame + elapsedFrames
        )
    }

    func startPlayheadUpdates() {
        playheadTask?.cancel()
        playheadTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .milliseconds(33))
                } catch {
                    return
                }
                guard !Task.isCancelled else {
                    return
                }
                await self?.publishPlayhead()
            }
        }
    }

    func publishPlayhead() {
        if playbackTarget == .take {
            guard let takeInfo else {
                return
            }
            let position = Double(currentTakeFrame()) / takeInfo.sampleRate
            eventContinuation.yield(.playheadChanged(position))
            return
        }
        guard let sourceInfo else {
            return
        }
        let position = Double(currentSourceFrame()) / sourceInfo.sampleRate
        eventContinuation.yield(.playheadChanged(position))
        if let recordingContext {
            let progress = max(position - recordingContext.region.start, 0) / playbackRate
            eventContinuation.yield(.recordingProgress(progress))
        }
    }

    func makeLoopScheduler() throws -> RegionLoopScheduler? {
        guard let loopRegion, let sourceInfo else {
            return nil
        }
        return try RegionLoopScheduler(
            region: loopRegion,
            converter: AudioFrameTimeConverter(sampleRate: sourceInfo.sampleRate),
            playbackRate: playbackRate
        )
    }

    func handlePlaybackFinished(generation: UInt64) async {
        guard generation == scheduleGeneration, playbackTarget == .original else {
            return
        }
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
        } else {
            if let sourceInfo {
                pausedFrame = sourceInfo.frameCount
                eventContinuation.yield(.playheadChanged(sourceInfo.duration))
            }
            eventContinuation.yield(.playbackFinished)
        }
    }

    func handleTakePlaybackFinished(generation: UInt64) {
        guard generation == takeScheduleGeneration, playbackTarget == .take else {
            return
        }
        isPlaying = false
        playheadTask?.cancel()
        if let takeInfo {
            takePausedFrame = takeInfo.frameCount
            eventContinuation.yield(.playheadChanged(takeInfo.duration))
        }
        eventContinuation.yield(.playbackFinished)
    }

    private func handleEngineConfigurationChange() async {
        engine.stop()
        if recordingContext != nil {
            eventContinuation.yield(.interrupted(.inputDeviceRemoved))
            do {
                try await finishRecording(reason: .inputDeviceRemoved)
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
        } else {
            pause()
            eventContinuation.yield(.interrupted(.outputDeviceChanged))
        }
    }

    private func handleSystemInterruption() async {
        eventContinuation.yield(.interrupted(.systemInterruption))
        if recordingContext != nil {
            do {
                try await finishRecording(reason: .systemInterruption)
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
        } else {
            pause()
        }
    }

    func stopPlayback(resetTo frame: Int64) {
        scheduleGeneration &+= 1
        takeScheduleGeneration &+= 1
        player.stop()
        takePlayer.stop()
        engine.stop()
        playheadTask?.cancel()
        isPlaying = false
        playbackTarget = .original
        pausedFrame = frame
        takePausedFrame = 0
    }

    func stopTakePlayback() {
        takeScheduleGeneration &+= 1
        takePlayer.stop()
        takeFile = nil
        takeInfo = nil
        takePausedFrame = 0
        takeScheduledStartFrame = 0
        if playbackTarget == .take {
            playbackTarget = .original
            isPlaying = false
            playheadTask?.cancel()
        }
    }
}
