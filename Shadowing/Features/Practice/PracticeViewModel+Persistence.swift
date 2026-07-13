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
        leaveConfirmation = nil
        leaveAfterFinalize = nil
        playheadPersistTask?.cancel()
        playheadPersistTask = nil
        recordingTask?.cancel()
        finalizationTask?.cancel()
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

    func schedulePlayheadPersist() {
        syncProjectSnapshot()
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
        await refreshTakes()
        await preloadTakeWaveforms()
        if let take = restoredSelectedTake() {
            activeTake = take
            project.selectedTakeID = take.id
            playhead = take.region.start
            project.playhead = take.region.start
            timelineViewport = .fitting(
                take.region,
                sourceDuration: project.duration
            )
            updateRegionNoticeForHydratedTake(take)
            return
        }

        if project.currentRegion != nil {
            loopEnabled = true
        }
        let position = min(max(playhead, 0), project.duration)
        playhead = position
        performVoidCommand { [audioClient, region = project.currentRegion] in
            if let region {
                try await audioClient.execute(.setLoop(region))
            }
            try await audioClient.execute(.seek(position))
        }
    }

    func attachScript() {
        guard !hasClosed, !controlsLocked else {
            return
        }
        guard let textFileChooser, let fileStore = recordingDependencies?.fileStore else {
            return
        }

        Task { [weak self] in
            guard let self else {
                return
            }
            guard let url = await textFileChooser.choosePlainText() else {
                return
            }
            do {
                try fileStore.commitScript(from: url, projectID: project.id)
                let text = try fileStore.loadScriptText(projectID: project.id) ?? ""
                project.scriptDisplayName = url.lastPathComponent
                scriptText = text
                persistProjectImmediately()
            } catch {
                show(error)
            }
        }
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
            recordingNotice = """
            This take keeps its recorded region \
            (\(Self.formatTime(take.region.start))–\(Self.formatTime(take.region.end))). \
            Changing the practice region does not change past takes.
            """
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
