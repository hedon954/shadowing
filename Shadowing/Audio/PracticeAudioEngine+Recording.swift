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
        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        guard inputFormat.channelCount > 0, inputFormat.sampleRate > 0 else {
            throw PracticeAudioEngineError.inputUnavailable
        }

        let pipeline = try RecordingPipeline(
            destinationURL: destinationURL,
            format: inputFormat
        )
        input.installTap(
            onBus: 0,
            bufferSize: 1024,
            format: inputFormat
        ) { buffer, _ in
            pipeline.capture(buffer)
        }

        recordingContext = RecordingContext(
            pipeline: pipeline,
            destinationURL: destinationURL,
            region: region,
            previousLoopRegion: loopRegion
        )
        startPeakForwarding(from: pipeline)

        do {
            try ensureEngineRunning()
            if playOriginal {
                loopRegion = nil
                let converter = try AudioFrameTimeConverter(sampleRate: sourceInfo.sampleRate)
                let startFrame = try converter.frame(at: region.start)
                let endFrame = try converter.frame(at: region.end)
                try schedulePlayback(from: startFrame, forcedEndFrame: endFrame)
                player.play()
                isPlaying = true
                startPlayheadUpdates()
            }
            eventContinuation.yield(.recordingStarted)
        } catch {
            input.removeTap(onBus: 0)
            recordingContext = nil
            recordingPeakTask?.cancel()
            try await failRecordingStart(
                pipeline: pipeline,
                destinationURL: destinationURL,
                startError: error
            )
        }
    }

    func stopRecording() async throws {
        guard recordingContext != nil else {
            throw PracticeAudioEngineError.recordingNotActive
        }
        try await finishRecording(reason: .manual)
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
            var batch: [Float] = []
            batch.reserveCapacity(8)
            for await peak in pipeline.peakStream {
                guard !Task.isCancelled else {
                    return
                }
                batch.append(peak)
                if batch.count == 8 {
                    await self?.publishRecordingPeaks(batch)
                    batch.removeAll(keepingCapacity: true)
                }
            }
            if !batch.isEmpty {
                await self?.publishRecordingPeaks(batch)
            }
        }
    }

    private func publishRecordingPeaks(_ peaks: [Float]) {
        eventContinuation.yield(.recordingPeaks(peaks))
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
