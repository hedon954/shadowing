@preconcurrency import AVFoundation
import Foundation

extension PracticeAudioEngine {
    func execute(_ command: PracticeAudioCommand) async throws {
        do {
            switch command {
            case let .loadSource(url):
                _ = try await load(sourceURL: url)
            case let .beginRecording(region, destinationURL, playOriginal):
                try await startRecording(
                    to: destinationURL,
                    region: region,
                    playOriginal: playOriginal
                )
            case .stopRecording:
                try await stopRecording()
            case .abortRecording:
                await abortRecording()
            default:
                try await executeTransport(command)
            }
        } catch {
            eventContinuation.yield(
                .failed(
                    PracticeAudioFailure(
                        operation: operation(for: command),
                        message: error.localizedDescription
                    )
                )
            )
            throw error
        }
    }

    @discardableResult
    func load(sourceURL: URL) async throws -> LoadedAudioSource {
        if recordingContext != nil {
            try await finishRecording(reason: .systemInterruption)
        }
        stopTakePlayback()
        stopPlayback(resetTo: 0)

        let file: AVAudioFile
        do {
            file = try AVAudioFile(forReading: sourceURL)
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
        sourceFile = file
        sourceInfo = info
        originalSourceURL = sourceURL
        pausedFrame = 0
        loopRegion = nil
        playbackTarget = .original
        // Warm the input node while loading so the first Record is less likely
        // to race a configuration-change interrupt.
        _ = engine.inputNode
        engine.prepare()
        eventContinuation.yield(.sourceLoaded(info))
        eventContinuation.yield(.playheadChanged(0))
        return info
    }

    private func executeTransport(_ command: PracticeAudioCommand) async throws {
        switch command {
        case let .playOriginal(region, position, rate):
            try await playOriginalCommand(region: region, from: position, rate: rate)
        case let .playOriginalSegment(region, position, rate):
            try await playOriginalSegmentCommand(region: region, from: position, rate: rate)
        case let .playTake(takeID, position, loop):
            try await playTakeCommand(takeID: takeID, from: position, loop: loop)
        case let .playTogether(region, takeID, rate):
            try await playTogetherCommand(region: region, takeID: takeID, rate: rate)
        case .pause:
            pause()
        case let .seek(position):
            try seek(to: position)
        case let .setRate(rate):
            try setRate(rate)
        case let .setVolume(volume):
            try setVolume(volume)
        case let .setLoop(region):
            try setLoop(region)
        case .loadSource, .beginRecording, .stopRecording, .abortRecording:
            return
        }
    }

    private func playOriginalCommand(
        region: PracticeRegion?,
        from position: TimeInterval,
        rate: Double
    ) async throws {
        stopTakePlaybackKeepingIdle()
        try setLoop(region)
        try setRate(rate)
        try play(from: position)
    }

    private func playOriginalSegmentCommand(
        region: PracticeRegion,
        from position: TimeInterval,
        rate: Double
    ) async throws {
        stopTakePlaybackKeepingIdle()
        try setLoop(nil)
        try setRate(rate)
        try playRegionOnce(region, from: position)
    }

    private func playTakeCommand(
        takeID: UUID,
        from position: TimeInterval,
        loop: PracticeRegion?
    ) async throws {
        guard let takeURLResolver else {
            throw PracticeAudioEngineError.takeResolutionUnavailable(takeID)
        }
        let takeURL = try await takeURLResolver(takeID)
        try playTake(url: takeURL, from: position, loop: loop)
    }

    private func playTogetherCommand(
        region: PracticeRegion,
        takeID: UUID,
        rate: Double
    ) async throws {
        guard let takeURLResolver else {
            throw PracticeAudioEngineError.takeResolutionUnavailable(takeID)
        }
        let takeURL = try await takeURLResolver(takeID)
        try playTogether(region: region, takeURL: takeURL, rate: rate)
    }

    private func stopTakePlaybackKeepingIdle() {
        takeScheduleGeneration &+= 1
        takePlayer.stop()
        takeLoopRegion = nil
        takeFirstScheduledFrameCount = 0
        if playbackTarget == .take {
            isPlaying = false
            playheadTask?.cancel()
        }
        playbackTarget = .original
    }

    private func operation(for command: PracticeAudioCommand) -> PracticeAudioOperation {
        switch command {
        case .loadSource:
            .loading
        case .beginRecording, .stopRecording, .abortRecording:
            .recording
        default:
            .playback
        }
    }
}
