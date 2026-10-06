@preconcurrency import AVFoundation
import Foundation

enum PracticeAudioEngineError: Error, Equatable, LocalizedError, Sendable {
    case sourceNotLoaded
    case invalidPlaybackRate(Double)
    case invalidVolume(Float)
    case invalidSeekTime(TimeInterval)
    case frameCountTooLarge
    case recordingAlreadyActive
    case recordingNotActive
    case inputUnavailable
    case microphoneNotAuthorized
    case takeResolutionUnavailable(UUID)
    case audioEngineFailed(String)

    var errorDescription: String? {
        switch self {
        case .sourceNotLoaded:
            String(localized: "Load an audio source before starting playback.")
        case let .invalidPlaybackRate(rate):
            String(localized: "Playback rate \(rate) is outside the supported 0.5x–1.5x range.")
        case let .invalidVolume(volume):
            String(localized: "Volume \(volume) is outside the supported 0–1 range.")
        case let .invalidSeekTime(time):
            String(localized: "Cannot seek to invalid audio time \(time).")
        case .frameCountTooLarge:
            String(localized: "The scheduled audio range is too large for AVAudioPlayerNode.")
        case .recordingAlreadyActive:
            String(localized: "A microphone recording is already active.")
        case .recordingNotActive:
            String(localized: "There is no active microphone recording to stop.")
        case .inputUnavailable:
            String(localized: "No usable microphone input format is available.")
        case .microphoneNotAuthorized:
            String(localized: "Shadowing doesn't have access to the microphone.")
        case let .takeResolutionUnavailable(takeID):
            String(localized: "No recording URL resolver is configured for take \(takeID.uuidString).")
        case let .audioEngineFailed(reason):
            String(localized: "The audio engine failed: \(reason)")
        }
    }
}

extension PracticeAudioEngine {
    func startRecording(
        to destinationURL: URL,
        region: PracticeRegion,
        playOriginal: Bool
    ) async throws {
        guard recordingContext == nil else {
            throw PracticeAudioEngineError.recordingAlreadyActive
        }
        guard sourceFile != nil, let sourceInfo else {
            throw PracticeAudioEngineError.sourceNotLoaded
        }
        // PracticeViewModel asks for access before recording; never prompt from the engine.
        // A fresh input-only engine for this take: the playback engine never gets an input.
        guard let recorder = inputGate.recorderIfAuthorized() else {
            throw PracticeAudioEngineError.microphoneNotAuthorized
        }
        stopTakePlayback()

        let clock = RecordingAlignmentClock()
        let inputToken = UUID()
        let take: MicrophoneTake
        do {
            take = try MicrophoneTake(
                recorder: recorder,
                destinationURL: destinationURL,
                // Always cap at remaining source audio; loop selection is unrelated.
                maximumDuration: region.duration,
                clock: clock,
                onConfigurationChange: { [weak self] in
                    Self.hop(self) { await $0.handleRecorderConfigurationChange(inputToken: inputToken) }
                }
            )
        } catch {
            try? removeTemporaryRecording(at: destinationURL)
            throw error
        }
        recordingContext = RecordingContext(
            take: take,
            inputToken: inputToken,
            destinationURL: destinationURL,
            region: region,
            previousLoopRegion: loopRegion,
            clock: clock
        )
        startPeakForwarding(from: take.pipeline)
        do {
            // The original plays on the playback engine, untouched by the microphone.
            try startRecordingPlaybackIfNeeded(
                clock: clock,
                playOriginal: playOriginal,
                region: region,
                sourceInfo: sourceInfo
            )
        } catch {
            await abortRecording()
            throw error
        }
        eventHub.yield(.recordingStarted)
        startFirstAudioWatchdog(for: take.pipeline)
    }

    /// If no microphone buffer arrives shortly after R, the take ends without saving anything
    /// and the view model shows "No sound from the microphone".
    private func startFirstAudioWatchdog(for pipeline: RecordingPipeline) {
        firstAudioWatchdog?.cancel()
        firstAudioWatchdog = Task { [weak self] in
            let received = await pipeline.waitForFirstBuffer(timeout: MicrophoneTakeTiming.firstAudioTimeout)
            guard !received, !Task.isCancelled else {
                return
            }
            await self?.endRecordingWithoutAudio(pipeline: pipeline)
        }
    }

    private func endRecordingWithoutAudio(pipeline: RecordingPipeline) async {
        guard let context = recordingContext, context.take.pipeline === pipeline else {
            return
        }
        await abortRecording()
        eventHub.yield(.recordingNoAudio)
    }

    /// The take's input engine changed configuration (device switch, sample rate): restart the
    /// input, or end the take cleanly when it can't be restarted.
    func handleRecorderConfigurationChange(inputToken: UUID) async {
        guard let context = recordingContext, context.inputToken == inputToken else {
            return
        }
        if context.take.restartAfterConfigurationChange() {
            return
        }
        eventHub.yield(.interrupted(.inputDeviceRemoved))
        do {
            try await finishRecording(reason: .inputDeviceRemoved)
        } catch {
            eventHub.yield(
                .failed(PracticeAudioFailure(operation: .recording, message: error.localizedDescription))
            )
        }
    }

    private func startRecordingPlaybackIfNeeded(
        clock: RecordingAlignmentClock,
        playOriginal: Bool,
        region: PracticeRegion,
        sourceInfo: LoadedAudioSource
    ) throws {
        guard playOriginal else {
            return
        }
        loopRegion = nil
        let converter = try AudioFrameTimeConverter(sampleRate: sourceInfo.sampleRate)
        let startFrame = try converter.frame(at: region.start)
        let endFrame = try converter.frame(at: region.end)
        try schedulePlayback(from: startFrame, forcedEndFrame: endFrame)
        try ensureEngineRunning()
        // Start at a known host time so the take can be aligned to the original afterwards.
        let startHostTime = mach_absolute_time() + AVAudioTime.hostTime(forSeconds: 0.05)
        player.play(at: AVAudioTime(hostTime: startHostTime))
        clock.notePlayerStart(hostTime: startHostTime)
        isPlaying = true
        startPlayheadUpdates()
    }

    func stopRecording() async throws {
        guard recordingContext != nil else {
            throw PracticeAudioEngineError.recordingNotActive
        }
        try await finishRecording(reason: .manual)
    }

    /// Cancels an armed or active recording without emitting `recordingFinished`.
    func abortRecording() async {
        guard let context = recordingContext else {
            return
        }
        recordingContext = nil
        firstAudioWatchdog?.cancel()
        firstAudioWatchdog = nil
        // The recorder is thrown away with the take.
        context.take.stopInput()
        recordingPeakTask?.cancel()
        recordingPeakTask = nil
        player.stop()
        isPlaying = false
        playheadTask?.cancel()
        loopRegion = context.previousLoopRegion
        do {
            _ = try await context.take.pipeline.finishKeepingAudio(timeout: MicrophoneTakeTiming.finishTimeout)
        } catch {
            // Best-effort cleanup; the temporary file is removed below either way.
            _ = error
        }
        try? removeTemporaryRecording(at: context.destinationURL)
    }

    func finishRecording(reason: RecordingStopReason) async throws {
        guard let context = recordingContext else {
            return
        }
        recordingContext = nil
        firstAudioWatchdog?.cancel()
        firstAudioWatchdog = nil
        let inputLatency = context.take.inputLatency
        // The recorder is thrown away with the take.
        context.take.stopInput()
        let outputLatency = engine.outputNode.presentationLatency
        recordingPeakTask?.cancel()
        recordingPeakTask = nil
        player.stop()
        isPlaying = false
        playheadTask?.cancel()
        loopRegion = context.previousLoopRegion

        let finished: RecordingPipelineResult?
        do {
            // Never waits forever: gives up after a timeout and deletes the file.
            finished = try await context.take.pipeline.finishKeepingAudio(timeout: MicrophoneTakeTiming.finishTimeout)
        } catch {
            do {
                try removeTemporaryRecording(at: context.destinationURL)
            } catch let cleanupError {
                throw PracticeAudioEngineError.audioEngineFailed(
                    "Recording failed: \(error.localizedDescription); " +
                        "cleanup failed: \(cleanupError.localizedDescription)"
                )
            }
            throw error
        }
        guard let result = finished else {
            // No audio at all: the file is gone and no take is saved.
            eventHub.yield(.recordingNoAudio)
            return
        }
        if result.droppedBufferCount > 0 {
            try removeTemporaryRecording(at: result.url)
            throw RecordingPipelineError.bufferQueueOverrun
        }
        let offset = inputLatency.flatMap { inputLatency in
            context.clock.offset(outputLatency: outputLatency, inputLatency: inputLatency)
        }
        if let offset {
            eventHub.yield(.recordingAlignmentMeasured(offset))
        }
        eventHub.yield(
            .recordingFinished(
                url: result.url,
                duration: result.duration,
                reason: reason
            )
        )
    }

    private func startPeakForwarding(from pipeline: RecordingPipeline) {
        recordingPeakTask?.cancel()
        recordingPeakTask = Task { [weak self] in
            for await update in pipeline.updateStream {
                guard !Task.isCancelled else {
                    return
                }
                await self?.publishRecordingUpdate(update)
            }
        }
    }

    private func publishRecordingUpdate(_ update: RecordingPipelineUpdate) async {
        guard recordingContext != nil else {
            return
        }
        eventHub.yield(.recordingProgress(update.elapsed))
        if !update.points.isEmpty {
            eventHub.yield(.recordingEnvelope(update.points))
        }
        guard update.reachedLimit else {
            return
        }
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
    }

    private func removeTemporaryRecording(at url: URL) throws {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return
        }
        try FileManager.default.removeItem(at: url)
    }
}

struct RecordingContext {
    let take: MicrophoneTake
    let inputToken: UUID
    let destinationURL: URL
    let region: PracticeRegion
    let previousLoopRegion: PracticeRegion?
    let clock: RecordingAlignmentClock
}
