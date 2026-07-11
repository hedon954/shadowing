import Foundation

extension PracticeViewModel {
    func receive(_ event: PracticeAudioEvent) {
        switch event {
        case .recordingStarted,
             .recordingProgress,
             .recordingEnvelope,
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
            if playingTakeID != nil {
                handleTakePlaybackFinished()
            } else {
                handlePlaybackFinished()
            }
        case let .interrupted(interruption):
            handleInterruption(interruption)
        case let .failed(audioFailure):
            handleAudioFailure(audioFailure)
        case .recordingStarted,
             .recordingProgress,
             .recordingEnvelope,
             .recordingFinished:
            break
        }
    }

    func receiveRecordingEvent(_ event: PracticeAudioEvent) {
        switch event {
        case .recordingStarted:
            handleRecordingStartedEvent()
        case let .recordingProgress(elapsed):
            handleRecordingProgressEvent(elapsed)
        case let .recordingEnvelope(points):
            guard case .recording = recordingPresentation else {
                return
            }
            appendLiveEnvelope(points)
        case let .recordingFinished(url, duration, reason):
            handleRecordingFinishedEvent(url: url, duration: duration, reason: reason)
        case .sourceLoaded,
             .playheadChanged,
             .playbackFinished,
             .interrupted,
             .failed:
            break
        }
    }

    private func handleRecordingStartedEvent() {
        switch recordingPresentation {
        case .checkingPermission, .countingDown, .recording:
            recordingPresentation = .recording(elapsed: 0)
            playhead = recordingContext?.region.start ?? playhead
        case .idle, .finalizing:
            Task { [weak self] in
                await self?.abortEngineRecordingIfNeeded()
            }
        }
    }

    private func handleRecordingProgressEvent(_ elapsed: TimeInterval) {
        guard case .recording = recordingPresentation else {
            return
        }
        recordingPresentation = .recording(elapsed: elapsed)
        if let region = recordingContext?.region {
            playhead = min(
                region.start + elapsed * recordingTimelineRate,
                region.end
            )
            revealRecordingProgress(at: playhead)
        }
    }

    private func handleRecordingFinishedEvent(
        url: URL,
        duration: TimeInterval,
        reason: RecordingStopReason
    ) {
        guard recordingContext != nil else {
            return
        }
        recordingPresentation = .finalizing
        finalizationTask?.cancel()
        finalizationTask = Task { [weak self] in
            await self?.finishRecording(url: url, duration: duration, reason: reason)
            self?.finalizationTask = nil
        }
    }

    func persistPosition() {
        persistProjectImmediately()
    }

    func discardPendingRecording() {
        if let context = recordingContext, let recordingDependencies {
            do {
                try recordingDependencies.fileStore.discardTemporaryTake(
                    at: context.temporaryURL
                )
            } catch {
                show(error)
            }
        }
        recordingContext = nil
        recordingWindow = nil
        recordingTimelineRate = 1
        recordingPresentation = .idle
        interactionPhase = .practicing
    }

    func discardPendingRecordingAbortingEngine() async {
        discardPendingRecording()
        await abortEngineRecordingIfNeeded()
    }

    func abortEngineRecordingIfNeeded() async {
        do {
            try await audioClient.execute(.abortRecording)
        } catch {
            _ = error
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
        if let take = currentlyPlayingTake() {
            playhead = take.region.start + min(
                max(position, 0),
                take.duration
            )
            followPlayheadInTimeline(at: playhead)
            return
        }
        playhead = min(max(position, 0), project.duration)
        if isPlaying {
            schedulePlayheadPersist()
            followPlayheadInTimeline(at: playhead)
        }
    }

    private func handlePlaybackFinished() {
        isPlaying = false
        playingTakeID = nil
        playhead = project.duration
        persistProjectImmediately()
    }

    private func handleInterruption(_ interruption: PracticeAudioInterruption) {
        playingTakeID = nil
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
