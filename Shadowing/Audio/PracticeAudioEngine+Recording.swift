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
    case takeResolutionUnavailable(UUID)
    case audioEngineFailed(String)

    var errorDescription: String? {
        switch self {
        case .sourceNotLoaded:
            "Load an audio source before starting playback."
        case let .invalidPlaybackRate(rate):
            "Playback rate \(rate) is outside the supported 0.5x–1.5x range."
        case let .invalidVolume(volume):
            "Volume \(volume) is outside the supported 0–1 range."
        case let .invalidSeekTime(time):
            "Cannot seek to invalid audio time \(time)."
        case .frameCountTooLarge:
            "The scheduled audio range is too large for AVAudioPlayerNode."
        case .recordingAlreadyActive:
            "A microphone recording is already active."
        case .recordingNotActive:
            "There is no active microphone recording to stop."
        case .inputUnavailable:
            "No usable microphone input format is available."
        case let .takeResolutionUnavailable(takeID):
            "No recording URL resolver is configured for take \(takeID)."
        case let .audioEngineFailed(reason):
            "The audio engine failed: \(reason)"
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
        stopTakePlayback()

        isArmingRecording = true
        let input = engine.inputNode
        var installedTap = false
        var pipeline: RecordingPipeline?

        do {
            let createdPipeline = try armRecordingPipeline(
                input: input,
                destinationURL: destinationURL,
                // Always cap at remaining source audio; loop selection is unrelated.
                maximumDuration: region.duration
            )
            pipeline = createdPipeline
            installedTap = true
            recordingContext = RecordingContext(
                pipeline: createdPipeline,
                destinationURL: destinationURL,
                region: region,
                previousLoopRegion: loopRegion
            )
            startPeakForwarding(from: createdPipeline)
            try startRecordingPlaybackIfNeeded(
                playOriginal: playOriginal,
                region: region,
                sourceInfo: sourceInfo
            )
            eventContinuation.yield(.recordingStarted)
            // Allow queued configuration-change tasks to observe isArmingRecording.
            await Task.yield()
            isArmingRecording = false
        } catch {
            if installedTap {
                input.removeTap(onBus: 0)
            }
            recordingContext = nil
            recordingPeakTask?.cancel()
            recordingPeakTask = nil
            isArmingRecording = false
            if let pipeline {
                try await failRecordingStart(
                    pipeline: pipeline,
                    destinationURL: destinationURL,
                    startError: error
                )
            }
            throw error
        }
    }

    /// Stabilizes the input graph, creates the writer, and installs the mic tap.
    private func armRecordingPipeline(
        input: AVAudioInputNode,
        destinationURL: URL,
        maximumDuration: TimeInterval?
    ) throws -> RecordingPipeline {
        // Starting the engine after recordingContext is set can emit a
        // configuration-change interrupt that immediately finalizes an empty take.
        try prepareInputGraph(input: input)
        let inputFormat = try resolvedInputFormat(from: input)
        let pipeline = try RecordingPipeline(
            destinationURL: destinationURL,
            format: inputFormat,
            maximumDuration: maximumDuration
        )
        input.installTap(
            onBus: 0,
            bufferSize: 4096,
            format: nil
        ) { buffer, _ in
            pipeline.capture(buffer)
        }
        return pipeline
    }

    private func startRecordingPlaybackIfNeeded(
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
        player.play()
        isPlaying = true
        startPlayheadUpdates()
    }

    /// Prepares and starts the engine so microphone formats report usable channel counts.
    func prepareInputGraph(input: AVAudioInputNode) throws {
        _ = input
        try ensureEngineRunning()
    }

    func resolvedInputFormat(from input: AVAudioInputNode) throws -> AVAudioFormat {
        let candidates = [
            input.outputFormat(forBus: 0),
            input.inputFormat(forBus: 0)
        ]
        for format in candidates where format.channelCount > 0 && format.sampleRate > 0 {
            return format
        }
        throw PracticeAudioEngineError.inputUnavailable
    }

    func stopRecording() async throws {
        guard recordingContext != nil else {
            throw PracticeAudioEngineError.recordingNotActive
        }
        try await finishRecording(reason: .manual)
    }

    /// Cancels an armed or active recording without emitting `recordingFinished`.
    func abortRecording() async {
        isArmingRecording = false
        guard let context = recordingContext else {
            return
        }
        recordingContext = nil
        engine.inputNode.removeTap(onBus: 0)
        recordingPeakTask?.cancel()
        recordingPeakTask = nil
        player.stop()
        isPlaying = false
        playheadTask?.cancel()
        loopRegion = context.previousLoopRegion
        do {
            _ = try await context.pipeline.finish()
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
        engine.inputNode.removeTap(onBus: 0)
        recordingPeakTask?.cancel()
        recordingPeakTask = nil
        player.stop()
        isPlaying = false
        playheadTask?.cancel()

        let result: RecordingPipelineResult
        do {
            result = try await context.pipeline.finish()
            loopRegion = context.previousLoopRegion
        } catch {
            loopRegion = context.previousLoopRegion
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
        if result.droppedBufferCount > 0 {
            try removeTemporaryRecording(at: result.url)
            throw RecordingPipelineError.bufferQueueOverrun
        }
        eventContinuation.yield(
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
        eventContinuation.yield(.recordingProgress(update.elapsed))
        if !update.points.isEmpty {
            eventContinuation.yield(.recordingEnvelope(update.points))
        }
        guard update.reachedLimit else {
            return
        }
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
    }

    private func failRecordingStart(
        pipeline: RecordingPipeline,
        destinationURL: URL,
        startError: Error
    ) async throws -> Never {
        var cleanupFailure: Error?
        do {
            _ = try await pipeline.finish()
        } catch {
            cleanupFailure = error
        }
        do {
            try removeTemporaryRecording(at: destinationURL)
        } catch {
            cleanupFailure = cleanupFailure ?? error
        }
        if let cleanupFailure {
            throw PracticeAudioEngineError.audioEngineFailed(
                "Recording start failed: \(startError.localizedDescription); " +
                    "cleanup failed: \(cleanupFailure.localizedDescription)"
            )
        }
        throw startError
    }

    private func removeTemporaryRecording(at url: URL) throws {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return
        }
        try FileManager.default.removeItem(at: url)
    }
}

struct RecordingContext: Sendable {
    let pipeline: RecordingPipeline
    let destinationURL: URL
    let region: PracticeRegion
    let previousLoopRegion: PracticeRegion?
}
