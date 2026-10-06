import Foundation

extension PracticeViewModel {
    var needsLeaveConfirmation: Bool {
        recordingPresentation.locksPracticeControls
    }

    func requestLeave(then leave: @escaping @MainActor () -> Void) {
        guard !hasClosed else {
            leave()
            return
        }
        guard needsLeaveConfirmation else {
            Task {
                await close()
                leave()
            }
            return
        }
        leaveAfterFinalize = leave
        leaveConfirmation = PracticeLeaveConfirmation()
    }

    func cancelLeave() {
        leaveConfirmation = nil
        leaveAfterFinalize = nil
    }

    func confirmStopAndLeave() {
        leaveConfirmation = nil
        let leave = leaveAfterFinalize
        leaveAfterFinalize = nil
        switch recordingPresentation {
        case .recording:
            leaveAfterFinalize = leave
            stopRecording()
        case .countingDown, .checkingPermission:
            let preparing = recordingTask
            recordingTask?.cancel()
            recordingTask = Task { [weak self] in
                _ = await preparing?.result
                await self?.discardPendingRecordingAbortingEngine()
                await self?.close()
                leave?()
                self?.recordingTask = nil
            }
        case .finalizing:
            leaveAfterFinalize = leave
        case .idle:
            Task {
                await close()
                leave?()
            }
        }
    }

    func close() async {
        guard !hasClosed else {
            return
        }
        hasClosed = true
        subtitles.close()
        leaveConfirmation = nil
        leaveAfterFinalize = nil
        playheadPersistTask?.cancel()
        playheadPersistTask = nil
        recordingTask?.cancel()
        finalizationTask?.cancel()
        appActivationTask?.cancel()
        appActivationTask = nil
        // Leaving (e.g. switching project) ends Compare and every transport gate here, so none
        // of them outlives this practice; the engine is paused below.
        cancelComparison()
        restoringPlayheadAfterComparison = nil
        pendingLocalSeek = nil
        suspendPlayheadFollow = false
        deferredTimelineReveal = nil
        playingTakeID = nil
        var closeError: Error?
        if case .countingDown = recordingPresentation {
            await discardPendingRecordingAbortingEngine()
        } else if case .checkingPermission = recordingPresentation {
            await discardPendingRecordingAbortingEngine()
        } else if case .recording = recordingPresentation {
            do {
                try await audioClient.execute(.stopRecording)
            } catch is CancellationError {
                // Closing cancels in-flight work.
            } catch {
                closeError = error
            }
            await discardPendingRecordingAbortingEngine()
        } else {
            await abortEngineRecordingIfNeeded()
        }
        eventTask?.cancel()
        await commandTask?.value
        isPlaying = false

        do {
            try await audioClient.execute(.pause)
        } catch {
            closeError = closeError ?? error
        }
        do {
            syncProjectSnapshot()
            try await projects.save(project)
        } catch {
            closeError = closeError ?? error
        }
        await sessionPreparer.endSession()
        if let closeError {
            show(closeError)
        }
    }

    func syncProjectSnapshot() {
        project.playhead = min(max(playhead, 0), project.duration)
        project.playbackRate = rate
        project.loopEnabled = loopEnabled
        if restoredTimelineViewport {
            project.saveTimelineViewport(timelineViewport)
        }
    }

    /// Zoom and pan are saved (debounced, with the playhead) so a reopened project shows the
    /// same part of the waveform. Before hydrate has restored the saved range nothing is saved.
    func timelineViewportDidChange(from oldValue: TimelineViewport) {
        guard restoredTimelineViewport, !hasClosed, timelineViewport != oldValue else {
            return
        }
        schedulePlayheadPersist()
    }

    func persistProjectImmediately() {
        playheadPersistTask?.cancel()
        playheadPersistTask = nil
        syncProjectSnapshot()
        let snapshot = project
        Task { [weak self, projects] in
            do {
                try await projects.save(snapshot)
            } catch {
                self?.show(error)
            }
        }
    }

    /// Debounced save of the playhead, rate and visible range. Called on every playback tick:
    /// must not touch published state (`project` is synced when the save actually runs), or
    /// every tick redraws the practice screen.
    func schedulePlayheadPersist() {
        playheadPersistTask?.cancel()
        playheadPersistTask = Task { [weak self] in
            do {
                try await Task.sleep(for: self?.playheadPersistDelay ?? .milliseconds(400))
            } catch {
                return
            }
            guard !Task.isCancelled else {
                return
            }
            self?.persistProjectImmediately()
        }
    }

    func hydrateRestoredSession() async {
        guard !hasClosed else {
            return
        }
        await loadScript()
        subtitles.load(script: subtitleScript)
        await refreshTakes()
        await preloadTakeWaveforms()
        // Reopening puts back where the user was: the saved playhead (`playhead` starts there;
        // a seek made while hydrating wins) and visible range. A selected take stays selected
        // (and its region), but does not move the playhead.
        let position = min(max(playhead, 0), project.duration)
        playhead = position
        let take = restoredSelectedTake()
        if let take {
            activeTake = take
            project.selectedTakeID = take.id
            updateRegionNoticeForHydratedTake(take)
        } else if project.currentRegion != nil {
            loopEnabled = true
        }
        restoreTimelineViewport(focus: take?.region)
        performVoidCommand { [audioClient, region = take == nil ? project.currentRegion : nil] in
            if let region {
                try await audioClient.execute(.setLoop(region))
            }
            try await audioClient.execute(.seek(position))
        }
    }

    /// The saved visible range, exactly; without one (older projects) the selected take's
    /// region together with the playhead when both fit, else the playhead. Opening is an active
    /// jump either way, so the transcript scrolls to the current sentence.
    private func restoreTimelineViewport(focus: PracticeRegion?) {
        if let saved = project.savedTimelineViewport {
            timelineViewport = saved
            jumpReveal.reveal()
        } else if let focus {
            let start = min(focus.start, playhead)
            let end = max(focus.end, playhead)
            if let span = try? PracticeRegion(start: start, end: end, sourceDuration: project.duration) {
                timelineViewport = .fitting(span, sourceDuration: project.duration)
            } else {
                timelineViewport = .fitting(focus, sourceDuration: project.duration)
            }
            revealPlayhead()
        } else {
            revealPlayhead()
        }
        restoredTimelineViewport = true
    }

    func attachScript() {
        guard !hasClosed, let textFileChooser else {
            return
        }
        guard !controlsLocked else {
            show(ScriptAttachmentError.recordingInProgress)
            return
        }
        Task { [weak self] in
            guard let url = await textFileChooser.choosePlainText() else {
                return
            }
            self?.attachScript(from: url)
        }
    }

    /// Copies the chosen .txt in and hands it to the Subtitles inspector for alignment.
    func attachScript(from url: URL) {
        guard !hasClosed, let fileStore = recordingDependencies?.fileStore else {
            return
        }
        // A text chosen while a take is being recorded would change the subtitles mid-take.
        guard !controlsLocked else {
            show(ScriptAttachmentError.recordingInProgress)
            return
        }
        let projectID = project.id
        Task { [weak self] in
            do {
                let text = try await Self.commitScript(from: url, projectID: projectID, fileStore: fileStore)
                guard let self else {
                    return
                }
                project.scriptDisplayName = url.lastPathComponent
                scriptText = text
                persistProjectImmediately()
                subtitles.scriptDidChange(subtitleScript)
            } catch {
                self?.show(error)
            }
        }
    }

    var subtitleScript: SubtitleScript? {
        guard let scriptText, !scriptText.isEmpty else {
            return nil
        }
        return SubtitleScript(text: scriptText, displayName: project.scriptDisplayName ?? "")
    }

    /// File work stays off the main actor.
    private nonisolated static func commitScript(
        from url: URL,
        projectID: UUID,
        fileStore: any RecordingFileStore
    ) async throws -> String {
        try fileStore.commitScript(from: url, projectID: projectID)
        return try fileStore.loadScriptText(projectID: projectID) ?? ""
    }

    func loadScript() async {
        guard !hasClosed,
              let fileStore = recordingDependencies?.fileStore
        else {
            scriptText = nil
            return
        }
        do {
            let text = try fileStore.loadScriptText(projectID: project.id)
            scriptText = text
            if text == nil, project.scriptDisplayName != nil {
                project.scriptDisplayName = nil
                persistProjectImmediately()
            }
        } catch {
            scriptText = nil
            show(error)
        }
    }

    private func updateRegionNoticeForHydratedTake(_ take: Take) {
        if let currentRegion = project.currentRegion, take.region != currentRegion {
            recordingNotice = Self.regionSnapshotNotice(for: take)
        }
    }

    private func restoredSelectedTake() -> Take? {
        guard let selectedTakeID = project.selectedTakeID else {
            return nil
        }
        return takes.first(where: { $0.id == selectedTakeID })
    }

    func completePendingLeaveIfNeeded() {
        guard let leave = leaveAfterFinalize else {
            return
        }
        leaveAfterFinalize = nil
        Task {
            await close()
            leave()
        }
    }
}

enum ScriptAttachmentError: Error, Equatable, LocalizedError {
    case recordingInProgress

    var errorDescription: String? {
        String(localized: "Stop recording before adding a text file.")
    }
}
