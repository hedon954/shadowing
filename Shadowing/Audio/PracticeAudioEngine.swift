@preconcurrency import AppKit
@preconcurrency import AVFoundation
import Foundation

enum PracticePlaybackTarget: Equatable, Sendable {
    case original
    case take
    case together
}

enum PracticeAudioEngineConstructionError: Error, Equatable {
    /// XCTest must never open the real audio devices (or trigger the microphone prompt).
    case unavailableUnderTests
}

actor PracticeAudioEngine: PracticeAudioClient {
    typealias TakeURLResolver = @Sendable (UUID) async throws -> URL

    let player = AVAudioPlayerNode()
    let takePlayer = AVAudioPlayerNode()
    let timePitch = AVAudioUnitTimePitch()
    let takeURLResolver: TakeURLResolver?
    /// When a scheduled segment counts as done (track end, loop re-queue). Live that is when it
    /// has been heard; offline there is no device, so it is when it has been rendered.
    let segmentCallbackType: AVAudioPlayerNodeCompletionCallbackType
    /// Playback only. It never gets a microphone input: recording runs on a separate,
    /// throwaway input-only engine (see `MicrophoneInputGate` and `MicrophoneRecorder`).
    let engine = AVAudioEngine()
    /// Hands out one fresh microphone recorder per take, only once access is granted.
    let inputGate: MicrophoneInputGate<MicrophoneRecorder>
    /// One stream per subscriber (see `PracticeAudioEventHub`).
    let eventHub = PracticeAudioEventHub()

    var sourceFile: AVAudioFile?
    var sourceInfo: LoadedAudioSource?
    var originalSourceURL: URL?
    var takeFile: AVAudioFile?
    var takeInfo: LoadedAudioSource?
    var playbackTarget: PracticePlaybackTarget = .original
    var playbackRate: Double = 1
    var loopRegion: PracticeRegion?
    /// Take-local loop window while `playbackTarget == .take`.
    var takeLoopRegion: PracticeRegion?
    /// Stops take playback here (frames) instead of at the end of the file; used by Compare.
    var takeEndFrame: Int64?
    /// Set while the original plays a one-shot segment, so its end is not reported as track end.
    var originalSegmentEndFrame: Int64?
    var scheduledStartFrame: Int64 = 0
    var firstScheduledFrameCount: Int64 = 0
    /// Whether the current original schedule repeats the loop after its first segment.
    var scheduledLoops = false
    var scheduleGeneration: UInt64 = 0
    var takeScheduleGeneration: UInt64 = 0
    var isPlaying = false
    var pausedFrame: Int64 = 0
    var takePausedFrame: Int64 = 0
    var takeScheduledStartFrame: Int64 = 0
    var takeFirstScheduledFrameCount: Int64 = 0
    /// Whether the current take schedule repeats the take loop after its first segment.
    var takeScheduledLoops = false
    var playheadTask: Task<Void, Never>?
    var recordingContext: RecordingContext?
    var recordingPeakTask: Task<Void, Never>?
    /// Ends the take if the microphone delivers nothing shortly after R.
    var firstAudioWatchdog: Task<Void, Never>?
    /// NotificationCenter tokens are only mutated during initialization and deinitialization.
    private nonisolated(unsafe) var notificationTokens: [NSObjectProtocol] = []
    private nonisolated(unsafe) var workspaceNotificationTokens: [NSObjectProtocol] = []

    private init(
        takeURLResolver: TakeURLResolver?,
        microphoneStatus: @escaping MicrophoneInputGate<MicrophoneRecorder>.StatusProvider,
        offlineRenderingFormat: AVAudioFormat? = nil
    ) throws {
        self.takeURLResolver = takeURLResolver
        segmentCallbackType = offlineRenderingFormat == nil ? .dataPlayedBack : .dataRendered
        inputGate = MicrophoneInputGate(status: microphoneStatus, makeRecorder: MicrophoneRecorder.init)
        if let offlineRenderingFormat {
            // Before any node exists: the output node is then a render target, not a device.
            try engine.enableManualRenderingMode(
                .offline,
                format: offlineRenderingFormat,
                maximumFrameCount: 4096
            )
        }
        Self.connectPlaybackGraph(on: engine, player: player, takePlayer: takePlayer, timePitch: timePitch)

        // The playback engine only; each take's recorder watches its own input engine.
        let token = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: nil
        ) { [weak self] _ in
            Self.hop(self) { await $0.handleEngineConfigurationChange() }
        }
        notificationTokens.append(token)

        let workspaceCenter = NSWorkspace.shared.notificationCenter
        let sleepToken = workspaceCenter.addObserver(
            forName: NSWorkspace.willSleepNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            Self.hop(self) { await $0.handleSystemInterruption() }
        }
        workspaceNotificationTokens.append(sleepToken)
    }

    deinit {
        playheadTask?.cancel()
        recordingPeakTask?.cancel()
        firstAudioWatchdog?.cancel()
        eventHub.finish()
        for token in notificationTokens {
            NotificationCenter.default.removeObserver(token)
        }
        for token in workspaceNotificationTokens {
            NSWorkspace.shared.notificationCenter.removeObserver(token)
        }
    }

    nonisolated func eventStream() -> AsyncStream<PracticeAudioEvent> {
        eventHub.makeStream()
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

    /// Keeps a position inside the file. A loop never moves it: a playhead outside the loop
    /// stays where it is (seek, setLoop and play all go through here).
    func normalizedPlaybackFrame(_ requestedFrame: Int64) throws -> Int64 {
        guard let sourceInfo else {
            throw PracticeAudioEngineError.sourceNotLoaded
        }
        return min(max(requestedFrame, 0), max(sourceInfo.frameCount - 1, 0))
    }

    func currentSourceFrame() -> Int64 {
        guard isPlaying,
              playbackTarget == .original || playbackTarget == .together,
              let renderTime = player.lastRenderTime,
              let playerTime = player.playerTime(forNodeTime: renderTime)
        else {
            return pausedFrame
        }
        let elapsedFrames = max(Int64(playerTime.sampleTime), 0)
        // Not looping this run (no loop, or started after the loop's end): a straight run.
        guard let loopRegion, let sourceInfo, scheduledLoops else {
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
        // Not looping this run (no loop, or started after the loop's end): a straight run.
        guard let takeLoopRegion, let takeInfo, takeScheduledLoops else {
            return min(
                takeScheduledStartFrame + elapsedFrames,
                takeInfo?.frameCount ?? takeScheduledStartFrame + elapsedFrames
            )
        }
        let loopStart = Int64(
            (takeLoopRegion.start * takeInfo.sampleRate).rounded(.toNearestOrAwayFromZero)
        )
        let loopEnd = Int64(
            (takeLoopRegion.end * takeInfo.sampleRate).rounded(.toNearestOrAwayFromZero)
        )
        if elapsedFrames < takeFirstScheduledFrameCount {
            return min(takeScheduledStartFrame + elapsedFrames, loopEnd - 1)
        }
        let loopFrameCount = loopEnd - loopStart
        guard loopFrameCount > 0 else {
            return loopStart
        }
        return loopStart + (elapsedFrames - takeFirstScheduledFrameCount) % loopFrameCount
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
                await self?.publishPlayheadTick()
            }
        }
    }

    /// A timer tick hops onto the engine after its cancellation check, so it can arrive after
    /// a pause or a take's end: then it publishes nothing (after a take, `publishPlayhead`
    /// would report the original's old paused position).
    func publishPlayheadTick() {
        guard !Task.isCancelled, isPlaying else {
            return
        }
        publishPlayhead()
    }

    func publishPlayhead() {
        switch playbackTarget {
        case .take:
            guard let takeInfo else {
                return
            }
            let position = Double(currentTakeFrame()) / takeInfo.sampleRate
            eventHub.yield(.playheadChanged(position))
        case .original, .together:
            guard let sourceInfo else {
                return
            }
            let position = Double(currentSourceFrame()) / sourceInfo.sampleRate
            eventHub.yield(.playheadChanged(position))
            if let recordingContext {
                let progress = max(position - recordingContext.region.start, 0) / playbackRate
                eventHub.yield(.recordingProgress(progress))
            }
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

    /// The playback engine's output changed (headphones, another output device).
    private func handleEngineConfigurationChange() async {
        engine.stop()
        if recordingContext != nil {
            eventHub.yield(.interrupted(.inputDeviceRemoved))
            do {
                try await finishRecording(reason: .inputDeviceRemoved)
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
        } else if isPlaying {
            pause()
            eventHub.yield(.interrupted(.outputDeviceChanged))
        }
    }

    private func handleSystemInterruption() async {
        eventHub.yield(.interrupted(.systemInterruption))
        if recordingContext != nil {
            do {
                try await finishRecording(reason: .systemInterruption)
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
        takeFirstScheduledFrameCount = 0
        takeLoopRegion = nil
        if playbackTarget == .take {
            playbackTarget = .original
            isPlaying = false
            playheadTask?.cancel()
        }
    }

    func stopTakeNode() {
        takeScheduleGeneration &+= 1
        takePlayer.stop()
    }
}

extension PracticeAudioEngine {
    /// The real engine for the app. It drives the speakers and the microphone, so it refuses to
    /// exist in an XCTest process; tests use `PracticeAudioClient` fakes instead.
    static func live(
        takeURLResolver: TakeURLResolver? = nil,
        microphoneStatus: @escaping MicrophoneInputGate<MicrophoneRecorder>.StatusProvider =
            SystemMicrophonePermissionService.currentStatus,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> PracticeAudioEngine {
        guard !AppLaunchEnvironment.isRunningTests(environment: environment) else {
            throw PracticeAudioEngineConstructionError.unavailableUnderTests
        }
        return try PracticeAudioEngine(takeURLResolver: takeURLResolver, microphoneStatus: microphoneStatus)
    }

    /// The same engine rendering offline (AVAudioEngine manual rendering): no speakers, no
    /// microphone, no audio device at all. Engine-level tests drive it with
    /// `renderOffline(frames:)`, which plays exactly that much audio and returns it.
    static func offlineRendering(
        sampleRate: Double = 44100,
        takeURLResolver: TakeURLResolver? = nil
    ) throws -> PracticeAudioEngine {
        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2) else {
            throw PracticeAudioEngineError.audioEngineFailed("Unsupported offline format")
        }
        return try PracticeAudioEngine(
            takeURLResolver: takeURLResolver,
            microphoneStatus: { .denied },
            offlineRenderingFormat: format
        )
    }

    /// Offline only: renders `frames` output frames and returns their peak level.
    func renderOffline(frames: AVAudioFrameCount) throws -> Float {
        guard engine.isInManualRenderingMode,
              let buffer = AVAudioPCMBuffer(
                  pcmFormat: engine.manualRenderingFormat,
                  frameCapacity: engine.manualRenderingMaximumFrameCount
              )
        else {
            throw PracticeAudioEngineError.audioEngineFailed("Not rendering offline")
        }
        var remaining = frames
        var peak: Float = 0
        while remaining > 0 {
            let chunk = min(remaining, buffer.frameCapacity)
            guard try engine.renderOffline(chunk, to: buffer) == .success else {
                throw PracticeAudioEngineError.audioEngineFailed("Offline render failed")
            }
            if let channel = buffer.floatChannelData?[0] {
                for index in 0 ..< Int(buffer.frameLength) {
                    peak = max(peak, abs(channel[index]))
                }
            }
            remaining -= chunk
        }
        return peak
    }

    /// Original → time-pitch → mixer, and the take player straight into the mixer.
    private static func connectPlaybackGraph(
        on engine: AVAudioEngine,
        player: AVAudioPlayerNode,
        takePlayer: AVAudioPlayerNode,
        timePitch: AVAudioUnitTimePitch
    ) {
        engine.attach(player)
        engine.attach(takePlayer)
        engine.attach(timePitch)
        engine.connect(player, to: timePitch, format: nil)
        engine.connect(timePitch, to: engine.mainMixerNode, format: nil)
        engine.connect(takePlayer, to: engine.mainMixerNode, format: nil)
    }

    /// Hop from a `@Sendable` callback onto the actor without capturing mutable `self`.
    nonisolated static func hop(
        _ engine: PracticeAudioEngine?,
        _ operation: @escaping @Sendable (PracticeAudioEngine) async -> Void
    ) {
        guard let engine else {
            return
        }
        Task {
            await operation(engine)
        }
    }
}
