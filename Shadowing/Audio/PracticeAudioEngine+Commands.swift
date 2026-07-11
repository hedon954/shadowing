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
        eventContinuation.yield(.sourceLoaded(info))
        eventContinuation.yield(.playheadChanged(0))
        return info
    }

    private func executeTransport(_ command: PracticeAudioCommand) async throws {
        switch command {
        case let .playOriginal(region, position, rate):
            stopTakePlaybackKeepingIdle()
            try setLoop(region)
            try setRate(rate)
            try play(from: position)
        case let .playTake(takeID, position):
            guard let takeURLResolver else {
                throw PracticeAudioEngineError.takeResolutionUnavailable(takeID)
            }
            let takeURL = try await takeURLResolver(takeID)
            try playTake(url: takeURL, from: position)
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
        case .loadSource, .beginRecording, .stopRecording:
            return
        }
    }

    private func stopTakePlaybackKeepingIdle() {
        takeScheduleGeneration &+= 1
        takePlayer.stop()
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
        case .beginRecording, .stopRecording:
            .recording
        default:
            .playback
        }
    }
}
