import Foundation

enum RecordingPresentation: Equatable, Sendable {
    case idle
    case checkingPermission
    case countingDown(remainingSeconds: Int)
    case recording(elapsed: TimeInterval)
    case finalizing

    var locksPracticeControls: Bool {
        switch self {
        case .checkingPermission, .countingDown, .recording, .finalizing:
            true
        case .idle:
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
    let settings: (any SettingsStore)?
    let waveforms: (any WaveformPreparing)?
    /// Fallback when settings are unavailable (tests may inject a fixed value).
    let countdownSeconds: Int
    let playOriginalWhileRecording: Bool
    let now: @Sendable () -> Date
    let makeID: @Sendable () -> UUID

    init(
        permissions: any MicrophonePermissionService,
        countdownClock: any RecordingCountdownClock,
        fileStore: any RecordingFileStore,
        takes: any TakeRepository,
        committer: any TakeCommitting,
        settings: (any SettingsStore)? = nil,
        waveforms: (any WaveformPreparing)? = nil,
        countdownSeconds: Int = 0,
        playOriginalWhileRecording: Bool = false,
        now: @escaping @Sendable () -> Date = Date.init,
        makeID: @escaping @Sendable () -> UUID = UUID.init
    ) {
        self.permissions = permissions
        self.countdownClock = countdownClock
        self.fileStore = fileStore
        self.takes = takes
        self.committer = committer
        self.settings = settings
        self.waveforms = waveforms
        self.countdownSeconds = max(countdownSeconds, 0)
        self.playOriginalWhileRecording = playOriginalWhileRecording
        self.now = now
        self.makeID = makeID
    }

    func resolvedSettings() async -> AppSettings {
        guard let settings else {
            return AppSettings(
                countdownSeconds: countdownSeconds,
                playOriginalWhileRecording: playOriginalWhileRecording
            )
        }
        do {
            if let stored = try await settings.value(
                for: AppSettings.storeKey,
                as: AppSettings.self
            ) {
                return stored
            }
        } catch {
            return AppSettings(
                countdownSeconds: countdownSeconds,
                playOriginalWhileRecording: playOriginalWhileRecording
            )
        }
        return AppSettings.default
    }
}

struct PendingRecordingContext: Sendable {
    let id: UUID
    let region: PracticeRegion
    let sequence: Int
    let temporaryURL: URL
    let createdAt: Date
    let replacesExisting: Bool
    /// Relative path of the take being overwritten; nil when appending.
    let previousRelativePath: String?
    let previousRegionStart: TimeInterval?
    let previousDuration: TimeInterval?
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
    func startRecording() {
        guard recordingTask == nil else {
            return
        }
        // Finalization may still hold the task after presentation returns to idle.
        if case .idle = recordingPresentation {
            finalizationTask = nil
        }
        guard finalizationTask == nil,
              !recordingPresentation.locksPracticeControls
        else {
            return
        }
        guard let recordingDependencies else {
            show(PracticeRecordingError.unavailable)
            return
        }
        // Always anchor to the Original-track cursor on the source timeline.
        let recordingRegion: PracticeRegion
        do {
            recordingRegion = try makeRecordingWindowFromPlayhead()
        } catch {
            show(error)
            return
        }
        project.playhead = recordingRegion.start
        playhead = recordingRegion.start
        recordingWindow = recordingRegion
        ensurePlayheadVisibleForRecording(at: recordingRegion.start)
        recordingNotice = nil
        pauseTakePlaybackIfNeeded()
        recordingPresentation = .checkingPermission
        interactionPhase = .recording
        recordingTask = Task { [weak self] in
            await self?.prepareRecording(
                region: recordingRegion,
                dependencies: recordingDependencies
            )
        }
    }

    private func makeRecordingWindowFromPlayhead() throws -> PracticeRegion {
        let minimumDuration = PracticeRegion.minimumDuration
        guard project.duration >= minimumDuration else {
            throw DomainError.invalidTimeRange
        }
        let latestStart = project.duration - minimumDuration
        let start = min(max(playhead, 0), latestStart)
        return try PracticeRegion.takeAlignment(
            start: start,
            end: project.duration,
            sourceDuration: project.duration
        )
    }

    func stopRecording() {
        switch recordingPresentation {
        case .countingDown, .checkingPermission:
            let preparing = recordingTask
            recordingTask?.cancel()
            recordingTask = Task { [weak self] in
                _ = await preparing?.result
                await self?.discardPendingRecordingAbortingEngine()
                self?.recordingTask = nil
            }
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
        case .idle, .finalizing:
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
            await abortEngineRecordingIfNeeded()
            try Task.checkCancellation()
            try await pausePlaybackIfNeeded()
            guard try await ensureMicrophoneAuthorized(dependencies) else {
                recordingTask = nil
                return
            }
            try await armPendingRecording(region: region, dependencies: dependencies)
            try Task.checkCancellation()
            if case .checkingPermission = recordingPresentation {
                recordingPresentation = .recording(elapsed: 0)
            } else if case .countingDown = recordingPresentation {
                recordingPresentation = .recording(elapsed: 0)
            }
        } catch is CancellationError {
            await discardPendingRecordingAbortingEngine()
        } catch {
            handleRecordingFailure(error, reason: .writeFailure)
        }
        recordingTask = nil
    }

    private func pausePlaybackIfNeeded() async throws {
        guard isPlaying else {
            return
        }
        try await audioClient.execute(.pause)
        isPlaying = false
    }

    private func ensureMicrophoneAuthorized(
        _ dependencies: RecordingDependencies
    ) async throws -> Bool {
        var permission = await dependencies.permissions.authorizationStatus()
        if permission == .notDetermined {
            permission = await dependencies.permissions.requestAuthorization()
        }
        guard permission == .authorized else {
            microphonePermissionPrompt = permission
            recordingPresentation = .idle
            interactionPhase = .practicing
            recordingWindow = nil
            return false
        }
        try Task.checkCancellation()
        return true
    }

    private func armPendingRecording(
        region: PracticeRegion,
        dependencies: RecordingDependencies
    ) async throws {
        let overwriteTarget = activeTake
        let takeID: UUID
        let sequence: Int
        let createdAt: Date
        let replacesExisting: Bool
        if let overwriteTarget {
            takeID = overwriteTarget.id
            sequence = overwriteTarget.sequence
            createdAt = overwriteTarget.createdAt
            replacesExisting = true
        } else {
            let existingTakes = try await dependencies.takes.takes(projectID: project.id)
            takeID = dependencies.makeID()
            sequence = (existingTakes.map(\.sequence).max() ?? 0) + 1
            createdAt = dependencies.now()
            replacesExisting = false
        }
        let temporaryURL = try dependencies.fileStore.temporaryTakeURL(id: takeID)
        recordingContext = PendingRecordingContext(
            id: takeID,
            region: region,
            sequence: sequence,
            temporaryURL: temporaryURL,
            createdAt: createdAt,
            replacesExisting: replacesExisting,
            previousRelativePath: overwriteTarget?.relativeAudioPath,
            previousRegionStart: overwriteTarget?.region.start,
            previousDuration: overwriteTarget?.duration
        )
        liveRecordingPeaks = []
        liveRecordingEnvelope = []
        lastRecordingStopReason = nil
        if !replacesExisting {
            activeTake = nil
        }

        let appSettings = await dependencies.resolvedSettings()
        recordingTimelineRate = appSettings.playOriginalWhileRecording ? rate : 1
        recordingNotice = appSettings.playOriginalWhileRecording
            ? "Headphones are recommended to prevent the original audio from being recorded again."
            : nil
        try await runCountdown(
            dependencies,
            seconds: appSettings.normalizedCountdownSeconds
        )
        try Task.checkCancellation()
        playhead = region.start
        try await audioClient.execute(.seek(region.start))
        try Task.checkCancellation()
        try await audioClient.execute(
            .beginRecording(
                region: region,
                destinationURL: temporaryURL,
                playOriginal: appSettings.playOriginalWhileRecording
            )
        )
        try Task.checkCancellation()
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
            completePendingLeaveIfNeeded()
            return
        }

        do {
            let prepared = try TakeOverwriteCommit.prepare(
                newRecordingURL: url,
                duration: duration,
                context: context,
                sourceDuration: project.duration,
                fileStore: dependencies.fileStore
            )
            let draft = try TakeDraft(
                id: context.id,
                projectID: project.id,
                region: prepared.region,
                sequence: context.sequence,
                duration: prepared.duration,
                createdAt: context.createdAt
            )
            let take = try await dependencies.committer.commit(
                draft,
                temporaryFile: prepared.fileURL,
                replaceExisting: context.replacesExisting
            )
            recordingContext = nil
            recordingWindow = nil
            recordingPresentation = .idle
            interactionPhase = .practicing
            liveRecordingEnvelope = []
            liveRecordingPeaks = []
            await focusTake(take, preferExistingViewport: true)
            await loadTakeWaveform(for: take)
            completePendingLeaveIfNeeded()
        } catch {
            handleRecordingFailure(error, reason: reason)
        }
    }

    private func resolvedTakeRegion(
        context: PendingRecordingContext,
        duration: TimeInterval
    ) throws -> PracticeRegion {
        let end = min(context.region.start + duration, project.duration)
        return try PracticeRegion.takeAlignment(
            id: context.region.id,
            start: context.region.start,
            end: end,
            sourceDuration: project.duration
        )
    }

    func loadTakeWaveform(for take: Take) async {
        guard let recordingDependencies else {
            return
        }
        do {
            let url = try recordingDependencies.fileStore.audioURL(
                relativePath: take.relativeAudioPath
            )
            let waveform: WaveformPresentation = if let waveforms = recordingDependencies.waveforms {
                try await waveforms.prepareWaveform(from: url)
            } else {
                try await TakeWaveformPeaks.load(from: url)
            }
            guard !waveform.levels.isEmpty else {
                return
            }
            takeWaveforms[take.id] = waveform
            if activeTake?.id == take.id {
                selectedTakePeaks = waveform.peaks
            }
        } catch {
            _ = error
        }
    }

    /// Compatibility shim for older call sites / tests.
    func loadSelectedTakePeaks(for take: Take) async {
        await loadTakeWaveform(for: take)
    }

    func appendLivePeaks(_ peaks: [Float]) {
        liveRecordingPeaks.append(contentsOf: peaks.map { min(max($0, 0), 1) })
        let overflow = liveRecordingPeaks.count - Self.maximumLivePeakCount
        if overflow > 0 {
            liveRecordingPeaks.removeFirst(overflow)
        }
    }

    func appendLiveEnvelope(_ points: [TimedWaveformEnvelopePoint]) {
        liveRecordingEnvelope.append(contentsOf: points)
        let overflow = liveRecordingEnvelope.count - Self.maximumLiveEnvelopePointCount
        if overflow > 0 {
            liveRecordingEnvelope.removeFirst(overflow)
        }
        appendLivePeaks(points.map(\.envelope.amplitude))
    }

    func handleRecordingFailure(
        _ error: Error,
        reason: RecordingStopReason
    ) {
        lastRecordingStopReason = reason
        discardPendingRecording()
        Task { [weak self] in
            await self?.abortEngineRecordingIfNeeded()
        }
        show(error)
        completePendingLeaveIfNeeded()
    }

    private func runCountdown(
        _ dependencies: RecordingDependencies,
        seconds: Int
    ) async throws {
        guard seconds > 0 else {
            return
        }
        for remaining in stride(from: seconds, through: 1, by: -1) {
            try Task.checkCancellation()
            recordingPresentation = .countingDown(remainingSeconds: remaining)
            try await dependencies.countdownClock.waitForNextSecond()
        }
    }
}
