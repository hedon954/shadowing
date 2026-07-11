import Foundation

extension PracticeViewModel {
    func receive(_ event: PracticeAudioEvent) {
        switch event {
        case .recordingStarted,
             .recordingProgress,
             .recordingPeaks,
             .recordingFinished:
            receiveRecordingEvent(event)
        default:
            receiveTransportEvent(event)
        }
    }

    func receiveTransportEvent(_ event: PracticeAudioEvent) {
        switch event {
        case .sourceLoaded:
            break
        case let .playheadChanged(position):
            updatePlayhead(from: position)
        case .playbackFinished:
            handlePlaybackFinished()
        case let .interrupted(interruption):
            handleInterruption(interruption)
        case let .failed(audioFailure):
            handleAudioFailure(audioFailure)
        case .recordingStarted,
             .recordingProgress,
             .recordingPeaks,
             .recordingFinished:
            break
        }
    }

    func receiveRecordingEvent(_ event: PracticeAudioEvent) {
        switch event {
        case .recordingStarted:
            recordingPresentation = .recording(elapsed: 0)
            playhead = recordingContext?.region.start ?? playhead
        case let .recordingProgress(elapsed):
            recordingPresentation = .recording(elapsed: elapsed)
            if let region = recordingContext?.region {
                playhead = min(region.start + elapsed * rate, region.end)
            }
        case let .recordingPeaks(peaks):
            appendLivePeaks(peaks)
        case let .recordingFinished(url, duration, reason):
            recordingPresentation = .finalizing
            finalizationTask?.cancel()
            finalizationTask = Task { [weak self] in
                await self?.finishRecording(url: url, duration: duration, reason: reason)
                self?.finalizationTask = nil
            }
        case .sourceLoaded,
             .playheadChanged,
             .playbackFinished,
             .interrupted,
             .failed:
            break
        }
    }

    func persistPosition() {
        project.playhead = min(max(playhead, 0), project.duration)
        Task { [weak self, projects, project] in
            do {
                try await projects.save(project)
            } catch {
                self?.show(error)
            }
        }
    }

    func performVoidCommand(
        _ operation: @escaping @Sendable () async throws -> Void,
        completion: @escaping @MainActor () -> Void = {}
    ) {
        let previousCommand = commandTask
        commandTask = Task { [weak self] in
            await previousCommand?.value
            guard !Task.isCancelled else {
                return
            }
            do {
                try await operation()
                try Task.checkCancellation()
                completion()
            } catch is CancellationError {
                return
            } catch {
                self?.show(error)
            }
        }
    }

    func performCommand<Value: Sendable>(
        _ operation: @escaping @Sendable () async throws -> Value,
        completion: @escaping @MainActor (Value) -> Void
    ) {
        let previousCommand = commandTask
        commandTask = Task { [weak self] in
            await previousCommand?.value
            guard !Task.isCancelled else {
                return
            }
            do {
                let value = try await operation()
                try Task.checkCancellation()
                completion(value)
            } catch is CancellationError {
                return
            } catch {
                self?.show(error)
            }
        }
    }

    private func updatePlayhead(from position: TimeInterval) {
        if isComparing, comparisonMode == .selectedTake {
            playhead = min(max(position, 0), activeTake?.duration ?? position)
        } else {
            playhead = min(max(position, 0), project.duration)
        }
    }

    private func handlePlaybackFinished() {
        isPlaying = false
        if isComparing, comparisonMode == .selectedTake {
            playhead = activeTake?.duration ?? playhead
        } else if isComparing, let take = activeTake {
            playhead = take.region.end
        } else {
            playhead = project.duration
            persistPosition()
        }
    }

    private func handleInterruption(_ interruption: PracticeAudioInterruption) {
        isPlaying = false
        if recordingPresentation.locksPracticeControls {
            recordingPresentation = .finalizing
            recordingNotice = interruption == .inputDeviceRemoved
                ? "The microphone was disconnected. Saving the valid recorded portion."
                : "Recording was interrupted. Saving the valid recorded portion."
            return
        }
        show(
            AudioSourceError.failed(
                interruption == .outputDeviceChanged
                    ? "The audio output changed. Press Play to continue."
                    : "Playback was interrupted. Press Play to continue."
            )
        )
    }

    private func handleAudioFailure(_ audioFailure: PracticeAudioFailure) {
        isPlaying = false
        if audioFailure.operation == .recording {
            handleRecordingFailure(audioFailure, reason: .writeFailure)
        } else {
            show(audioFailure)
        }
    }
}
