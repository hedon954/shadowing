import Foundation

enum RecordingPresentation: Equatable, Sendable {
    case idle
    case checkingPermission
    case countingDown(remainingSeconds: Int)
    case recording(elapsed: TimeInterval)
    case finalizing
    case comparisonReady(Take)

    var locksPracticeControls: Bool {
        switch self {
        case .checkingPermission, .countingDown, .recording, .finalizing:
            true
        case .idle, .comparisonReady:
            false
        }
    }
}

struct RecordingDependencies: Sendable {
    let permissions: any MicrophonePermissionService
    let countdownClock: any RecordingCountdownClock
    let fileStore: any RecordingFileStore
    let takes: any TakeRepository
    let committer: any TakeCommitting
    let countdownSeconds: Int
    let now: @Sendable () -> Date
    let makeID: @Sendable () -> UUID

    init(
        permissions: any MicrophonePermissionService,
        countdownClock: any RecordingCountdownClock,
        fileStore: any RecordingFileStore,
        takes: any TakeRepository,
        committer: any TakeCommitting,
        countdownSeconds: Int = 3,
        now: @escaping @Sendable () -> Date = Date.init,
        makeID: @escaping @Sendable () -> UUID = UUID.init
    ) {
        self.permissions = permissions
        self.countdownClock = countdownClock
        self.fileStore = fileStore
        self.takes = takes
        self.committer = committer
        self.countdownSeconds = max(countdownSeconds, 0)
        self.now = now
        self.makeID = makeID
    }
}

struct PendingRecordingContext: Sendable {
    let id: UUID
    let region: PracticeRegion
    let sequence: Int
    let temporaryURL: URL
}

enum PracticeRecordingError: Error, Equatable, LocalizedError, Sendable {
    case unavailable
    case missingContext
    case unexpectedTemporaryFile(String)
    case tooShort(TimeInterval)

    var errorDescription: String? {
        switch self {
        case .unavailable:
            "Recording is unavailable in this practice session."
        case .missingContext:
            "The completed recording has no active recording session."
        case let .unexpectedTemporaryFile(path):
            "The audio engine returned an unexpected temporary recording at \(path)."
        case let .tooShort(duration):
            """
            The recording was only \
            \(duration.formatted(.number.precision(.fractionLength(1)))) seconds. \
            Please record again.
            """
        }
    }
}

extension PracticeViewModel {
    var originalRecordingRegionPeaks: [Float] {
        guard let region, project.duration > 0, !waveform.peaks.isEmpty else {
            return []
        }
        let startIndex = min(
            max(Int(region.start / project.duration * Double(waveform.peaks.count)), 0),
            waveform.peaks.count - 1
        )
        let endIndex = min(
            max(
                Int(ceil(region.end / project.duration * Double(waveform.peaks.count))),
                startIndex + 1
            ),
            waveform.peaks.count
        )
        return Array(waveform.peaks[startIndex ..< endIndex])
    }

    var recordingProgressFraction: Double {
        guard let region, region.duration > 0 else {
            return 0
        }
        switch recordingPresentation {
        case let .recording(elapsed):
            let expectedDuration = region.duration / rate
            return min(max(elapsed / expectedDuration, 0), 1)
        case .finalizing, .comparisonReady:
            return 1
        case .idle, .checkingPermission, .countingDown:
            return 0
        }
    }

    var recordingElapsed: TimeInterval {
        if case let .recording(elapsed) = recordingPresentation {
            return elapsed
        }
        return activeTake?.duration ?? 0
    }

    func startRecording() {
        guard recordingTask == nil,
              finalizationTask == nil,
              !recordingPresentation.locksPracticeControls
        else {
            return
        }
        guard let region else {
            show(PracticeTransitionError.missingPracticeRegion)
            return
        }
        guard let recordingDependencies else {
            show(PracticeRecordingError.unavailable)
            return
        }

        recordingNotice = "Headphones are recommended to prevent the original audio from being recorded again."
        recordingPresentation = .checkingPermission
        interactionPhase = .recording
        recordingTask = Task { [weak self] in
            await self?.prepareRecording(
                region: region,
                dependencies: recordingDependencies
            )
        }
    }

    func stopRecording() {
        switch recordingPresentation {
        case .countingDown, .checkingPermission:
            recordingTask?.cancel()
            recordingTask = nil
            discardPendingRecording()
        case .recording:
            recordingPresentation = .finalizing
            lastRecordingStopReason = .manual
            recordingTask = Task { [weak self, audioClient] in
                do {
                    try await audioClient.execute(.stopRecording)
                } catch is CancellationError {
                    return
                } catch {
                    self?.handleRecordingFailure(error, reason: .writeFailure)
                }
                self?.recordingTask = nil
            }
        case .idle, .finalizing, .comparisonReady:
            return
        }
    }

    func openMicrophoneSettings() {
        guard let recordingDependencies else {
            return
        }
        Task {
            await recordingDependencies.permissions.openSystemSettings()
        }
        microphonePermissionPrompt = nil
    }

    func dismissMicrophonePermissionPrompt() {
        microphonePermissionPrompt = nil
    }

    func prepareRecording(
        region: PracticeRegion,
        dependencies: RecordingDependencies
    ) async {
        do {
            if isPlaying {
                try await audioClient.execute(.pause)
                isPlaying = false
            }

            var permission = await dependencies.permissions.authorizationStatus()
            if permission == .notDetermined {
                permission = await dependencies.permissions.requestAuthorization()
            }
            guard permission == .authorized else {
                microphonePermissionPrompt = permission
                resetRecordingPresentation()
                recordingTask = nil
                return
            }

            let existingTakes = try await dependencies.takes.takes(
                projectID: project.id
            )
            let sequence = (existingTakes.map(\.sequence).max() ?? 0) + 1
            let takeID = dependencies.makeID()
            let temporaryURL = try dependencies.fileStore.temporaryTakeURL(
                id: takeID
            )
            recordingContext = PendingRecordingContext(
                id: takeID,
                region: region,
                sequence: sequence,
                temporaryURL: temporaryURL
            )
            liveRecordingPeaks = []
            activeTake = nil
            lastRecordingStopReason = nil

            try await runCountdown(dependencies)
            try Task.checkCancellation()
            playhead = region.start
            try await audioClient.execute(.seek(region.start))
            try await audioClient.execute(
                .beginRecording(
                    region: region,
                    destinationURL: temporaryURL,
                    playOriginal: true
                )
            )
        } catch is CancellationError {
            discardPendingRecording()
        } catch {
            handleRecordingFailure(error, reason: .writeFailure)
        }
        recordingTask = nil
    }

    func finishRecording(
        url: URL,
        duration: TimeInterval,
        reason: RecordingStopReason
    ) async {
        guard let dependencies = recordingDependencies,
              let context = recordingContext
        else {
            handleRecordingFailure(PracticeRecordingError.missingContext, reason: reason)
            return
        }
        guard context.temporaryURL.standardizedFileURL == url.standardizedFileURL else {
            handleRecordingFailure(
                PracticeRecordingError.unexpectedTemporaryFile(url.path),
                reason: reason
            )
            return
        }

        lastRecordingStopReason = reason
        guard duration >= PracticeRegion.minimumDuration else {
            discardPendingRecording()
            show(PracticeRecordingError.tooShort(duration))
            return
        }

        do {
            let draft = try TakeDraft(
                id: context.id,
                projectID: project.id,
                region: context.region,
                sequence: context.sequence,
                duration: duration,
                createdAt: dependencies.now()
            )
            let take = try await dependencies.committer.commit(
                draft,
                temporaryFile: url
            )
            recordingContext = nil
            activeTake = take
            project.selectedTakeID = take.id
            project.currentRegion = take.region
            project.playhead = take.region.start
            playhead = take.region.start
            do {
                try await projects.save(project)
            } catch {
                show(error)
            }
            recordingPresentation = .comparisonReady(take)
            interactionPhase = .practicing
        } catch {
            handleRecordingFailure(error, reason: reason)
        }
    }

    func appendLivePeaks(_ peaks: [Float]) {
        liveRecordingPeaks.append(contentsOf: peaks.map { min(max($0, 0), 1) })
        let overflow = liveRecordingPeaks.count - Self.maximumLivePeakCount
        if overflow > 0 {
            liveRecordingPeaks.removeFirst(overflow)
        }
    }

    func handleRecordingFailure(
        _ error: Error,
        reason: RecordingStopReason
    ) {
        lastRecordingStopReason = reason
        discardPendingRecording()
        show(error)
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
        resetRecordingPresentation()
    }

    private func runCountdown(
        _ dependencies: RecordingDependencies
    ) async throws {
        guard dependencies.countdownSeconds > 0 else {
            return
        }
        for remaining in stride(
            from: dependencies.countdownSeconds,
            through: 1,
            by: -1
        ) {
            try Task.checkCancellation()
            recordingPresentation = .countingDown(remainingSeconds: remaining)
            try await dependencies.countdownClock.waitForNextSecond()
        }
    }

    private func resetRecordingPresentation() {
        recordingPresentation = .idle
        interactionPhase = .practicing
    }
}
