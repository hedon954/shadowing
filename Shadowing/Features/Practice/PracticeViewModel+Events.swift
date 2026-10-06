import Foundation

extension PracticeViewModel {
    func receive(_ event: PracticeAudioEvent) {
        switch event {
        case .recordingStarted,
             .recordingProgress,
             .recordingEnvelope,
             .recordingAlignmentMeasured,
             .recordingFinished,
             .recordingNoAudio:
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
        case .segmentFinished:
            if !handleCompareSegmentFinished() {
                handleSegmentFinished()
            }
        case .playbackFinished:
            handleTrackPlaybackFinished()
        case let .interrupted(interruption):
            handleInterruption(interruption)
        case let .failed(audioFailure):
            handleAudioFailure(audioFailure)
        case .recordingStarted,
             .recordingProgress,
             .recordingEnvelope,
             .recordingAlignmentMeasured,
             .recordingFinished,
             .recordingNoAudio:
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
        case let .recordingAlignmentMeasured(offset):
            saveAlignmentOffset(offset)
        case let .recordingFinished(url, duration, reason):
            handleRecordingFinishedEvent(url: url, duration: duration, reason: reason)
        case .recordingNoAudio:
            handleRecordingNoAudio()
        case .sourceLoaded,
             .playheadChanged,
             .playbackFinished,
             .segmentFinished,
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
        // The file is closed; committing the take is not bounded by the saving timeout.
        savingWatchdogTask?.cancel()
        savingWatchdogTask = nil
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
        if let context = recordingContext {
            takeOffsets[context.id] = nil
            recordingDependencies?.alignment?.deleteOffset(for: context.id)
        }
        recordingContext = nil
        recordingWindow = nil
        recordingTimelineRate = 1
        recordingPresentation = .idle
        interactionPhase = .practicing
        savingWatchdogTask?.cancel()
        savingWatchdogTask = nil
    }

    /// The microphone delivered nothing (no audio within a couple of seconds, or a take with no
    /// frames). Nothing is saved; the controls come back with "No sound from the microphone".
    func handleRecordingNoAudio() {
        recordingTask?.cancel()
        recordingTask = nil
        discardPendingRecording()
        recordingIssue = .noMicrophoneAudio
        completePendingLeaveIfNeeded()
    }

    func retryAfterRecordingIssue() {
        recordingIssue = nil
        startRecording()
    }

    func dismissRecordingIssue() {
        recordingIssue = nil
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

    /// The engine applied the seek to `target`; its positions are current again. A newer seek
    /// keeps its own gate.
    func finishLocalSeek(_ target: TimeInterval) {
        if pendingLocalSeek == target {
            pendingLocalSeek = nil
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
        // Compare owns the transport: the main playhead stays frozen until it is restored.
        if comparison != nil || restoringPlayheadAfterComparison != nil {
            return
        }
        // A local seek is in flight: this position predates the jump.
        if pendingLocalSeek != nil {
            return
        }
        if let take = currentlyPlayingTake() {
            let local = min(max(position, 0), take.duration)
            let source = RecordingAlignment.sourceTime(
                forTakeTime: local,
                regionStart: take.region.start,
                offset: alignmentOffset(for: take.id)
            )
            playhead = min(max(source, take.region.start), take.region.end)
            followPlayheadInTimeline(at: playhead)
            return
        }
        playhead = min(max(position, 0), project.duration)
        if isPlaying {
            schedulePlayheadPersist()
            followPlayheadInTimeline(at: playhead)
        }
    }

    /// Only a real end of the main track (or a plain take playback) ends playback;
    /// never while Compare runs, whose items report `segmentFinished`.
    private func handleTrackPlaybackFinished() {
        guard comparison == nil else {
            return
        }
        if playingTakeID != nil {
            handleTakePlaybackFinished()
        } else {
            handlePlaybackFinished()
        }
    }

    /// A one-shot segment outside Compare (Return replays the sentence) ended: stop in place.
    private func handleSegmentFinished() {
        isPlaying = false
        playingTakeID = nil
        persistProjectImmediately()
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
                ? String(localized: "The microphone was disconnected. Saving the valid recorded portion.")
                : String(localized: "Recording was interrupted. Saving the valid recorded portion.")
            return
        }
        show(
            AudioSourceError.failed(
                interruption == .outputDeviceChanged
                    ? String(localized: "The audio output changed. Press Play to continue.")
                    : String(localized: "Playback was interrupted. Press Play to continue.")
            )
        )
    }

    private func handleAudioFailure(_ audioFailure: PracticeAudioFailure) {
        isPlaying = false
        pendingLocalSeek = nil
        if audioFailure.operation == .recording {
            handleRecordingFailure(audioFailure, reason: .writeFailure)
        } else {
            show(audioFailure)
        }
    }
}

/// A take that ended without being saved, shown with a Try Again button.
enum RecordingIssue: Equatable, Identifiable, Sendable {
    case noMicrophoneAudio

    var id: Self {
        self
    }
}
