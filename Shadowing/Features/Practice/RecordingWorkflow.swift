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
    let alignment: (any RecordingAlignmentStoring)?
    /// Where deleted takes go (the Trash in the app, a temporary folder in tests).
    let trash: FileTrasher
    /// Fallback when settings are unavailable (tests may inject a fixed value).
    let countdownSeconds: Int
    let playOriginalWhileRecording: Bool
    let now: @Sendable () -> Date
    let makeID: @Sendable () -> UUID
    /// Posts `NSApplication.didBecomeActiveNotification`; tests inject their own center.
    let appActivationCenter: NotificationCenter

    init(
        permissions: any MicrophonePermissionService,
        countdownClock: any RecordingCountdownClock,
        fileStore: any RecordingFileStore,
        takes: any TakeRepository,
        committer: any TakeCommitting,
        settings: (any SettingsStore)? = nil,
        waveforms: (any WaveformPreparing)? = nil,
        alignment: (any RecordingAlignmentStoring)? = nil,
        trash: FileTrasher,
        countdownSeconds: Int = 0,
        playOriginalWhileRecording: Bool = false,
        now: @escaping @Sendable () -> Date = Date.init,
        makeID: @escaping @Sendable () -> UUID = UUID.init,
        appActivationCenter: NotificationCenter = .default
    ) {
        self.permissions = permissions
        self.countdownClock = countdownClock
        self.fileStore = fileStore
        self.takes = takes
        self.committer = committer
        self.settings = settings
        self.waveforms = waveforms
        self.alignment = alignment
        self.trash = trash
        self.countdownSeconds = max(countdownSeconds, 0)
        self.playOriginalWhileRecording = playOriginalWhileRecording
        self.now = now
        self.makeID = makeID
        self.appActivationCenter = appActivationCenter
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
    let displayOrder: Int
    let temporaryURL: URL
    let createdAt: Date
}

enum PracticeRecordingError: Error, Equatable, LocalizedError, Sendable {
    case unavailable
    case missingContext
    case unexpectedTemporaryFile(String)
    case tooShort(TimeInterval)
    case savingTimedOut

    var errorDescription: String? {
        switch self {
        case .unavailable:
            String(localized: "Recording is unavailable in this practice session.")
        case .missingContext:
            String(localized: "The completed recording has no active recording session.")
        case let .unexpectedTemporaryFile(path):
            String(localized: "The audio engine returned an unexpected temporary recording at \(path).")
        case let .tooShort(duration):
            String(localized: """
            The recording was only \
            \(duration.formatted(.number.precision(.fractionLength(1)))) seconds. \
            Please record again.
            """)
        case .savingTimedOut:
            String(localized: "Saving the recording took too long. Nothing was saved.")
        }
    }
}

extension PracticeViewModel {
    func startRecording() {
        guard recordingTask == nil else {
            return
        }
        cancelComparison()
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
            startSavingWatchdog()
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

    /// Saving must never hang: if the engine hasn't closed the file in time, show an error,
    /// save nothing and give the controls back.
    func startSavingWatchdog() {
        savingWatchdogTask?.cancel()
        let timeout = savingTimeout
        savingWatchdogTask = Task { [weak self] in
            try? await Task.sleep(for: timeout)
            guard !Task.isCancelled else {
                return
            }
            self?.handleSavingTimedOut()
        }
    }

    func handleSavingTimedOut() {
        savingWatchdogTask = nil
        guard case .finalizing = recordingPresentation, finalizationTask == nil else {
            return
        }
        recordingTask?.cancel()
        recordingTask = nil
        handleRecordingFailure(PracticeRecordingError.savingTimedOut, reason: .writeFailure)
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
        // Every recording is a new take, even with a take selected: comparing takes against each
        // other is the point, so an earlier take is never overwritten (ADR-0012).
        let existingTakes = try await dependencies.takes.takes(projectID: project.id)
        let takeID = dependencies.makeID()
        let temporaryURL = try dependencies.fileStore.temporaryTakeURL(id: takeID)
        recordingContext = PendingRecordingContext(
            id: takeID,
            region: region,
            sequence: (existingTakes.map(\.sequence).max() ?? 0) + 1,
            displayOrder: TakeDisplayOrdering.nextTopDisplayOrder(existing: existingTakes),
            temporaryURL: temporaryURL,
            createdAt: dependencies.now()
        )
        liveRecordingPeaks = []
        liveRecordingEnvelope = []
        lastRecordingStopReason = nil
        activeTake = nil

        let appSettings = await dependencies.resolvedSettings()
        recordingTimelineRate = appSettings.playOriginalWhileRecording ? rate : 1
        recordingNotice = appSettings.playOriginalWhileRecording
            ? String(localized: "Headphones are recommended to prevent the original audio from being recorded again.")
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
            let draft = try TakeDraft(
                id: context.id,
                projectID: project.id,
                region: resolvedTakeRegion(context: context, duration: duration),
                sequence: context.sequence,
                displayOrder: context.displayOrder,
                duration: duration,
                createdAt: context.createdAt
            )
            let take = try await dependencies.committer.commit(draft, temporaryFile: url)
            forgetUndoDelete()
            recordingContext = nil
            recordingWindow = nil
            recordingPresentation = .idle
            interactionPhase = .practicing
            liveRecordingEnvelope = []
            liveRecordingPeaks = []
            await focusTake(take, preferExistingViewport: true)
            // Leave must not wait on waveform generation (invalid/temp files can be slow).
            if leaveAfterFinalize != nil {
                completePendingLeaveIfNeeded()
            } else {
                await loadTakeWaveform(for: take)
            }
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
