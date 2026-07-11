import Foundation

extension PracticeViewModel {
    var comparisonOriginalPeaks: [Float] {
        guard let take = activeTake else {
            return originalRecordingRegionPeaks
        }
        return peaks(for: take.region)
    }

    var comparisonProgressFraction: Double {
        guard let take = activeTake else {
            return 0
        }
        switch comparisonMode {
        case .original:
            guard take.region.duration > 0 else {
                return 0
            }
            return min(
                max((playhead - take.region.start) / take.region.duration, 0),
                1
            )
        case .selectedTake:
            guard take.duration > 0 else {
                return 0
            }
            return min(max(playhead / take.duration, 0), 1)
        }
    }

    func enterComparison(with take: Take, takePeaks: [Float] = []) async {
        activeTake = take
        selectedTakePeaks = takePeaks
        comparisonMode = .selectedTake
        project.selectedTakeID = take.id
        project.currentRegion = take.region
        project.playhead = take.region.start
        playhead = 0
        recordingPresentation = .comparisonReady(take)
        interactionPhase = .practicing
        await refreshTakes()
        do {
            try await projects.save(project)
        } catch {
            show(error)
        }
    }

    func selectTake(_ take: Take) {
        guard isComparing, take.projectID == project.id else {
            return
        }
        pauseComparisonPlaybackIfNeeded()
        let previousID = activeTake?.id
        activeTake = take
        if take.id != previousID {
            selectedTakePeaks = []
        }
        project.selectedTakeID = take.id
        recordingPresentation = .comparisonReady(take)
        playhead = comparisonMode == .original ? take.region.start : 0
        updateRegionSnapshotNotice(for: take)
        persistSelectedTake()
    }

    func setComparisonMode(_ mode: ComparisonMode) {
        guard isComparing, comparisonMode != mode else {
            return
        }
        pauseComparisonPlaybackIfNeeded()
        comparisonMode = mode
        if let take = activeTake {
            playhead = mode == .original ? take.region.start : 0
        }
    }

    func toggleComparisonPlayback() {
        guard isComparing, let take = activeTake else {
            return
        }
        if isPlaying {
            pauseComparisonPlaybackIfNeeded()
            return
        }

        switch comparisonMode {
        case .original:
            let from = take.region.start ..< take.region.end ~= playhead
                ? playhead
                : take.region.start
            performCommand { [audioClient, rate] in
                try await audioClient.execute(
                    .playOriginal(
                        region: take.region,
                        from: from,
                        rate: rate
                    )
                )
                return true
            } completion: { [weak self] playing in
                self?.isPlaying = playing
            }
        case .selectedTake:
            let from = playhead >= take.duration ? 0 : max(playhead, 0)
            performCommand { [audioClient] in
                try await audioClient.execute(
                    .playTake(takeID: take.id, from: from)
                )
                return true
            } completion: { [weak self] playing in
                self?.isPlaying = playing
            }
        }
    }

    func rerecord() {
        guard isComparing else {
            return
        }
        pauseComparisonPlaybackIfNeeded()
        if let take = activeTake {
            project.currentRegion = take.region
        }
        takePendingDeletion = nil
        startRecording()
    }

    func requestDeleteTake(_ take: Take? = nil) {
        guard isComparing else {
            return
        }
        takePendingDeletion = take ?? activeTake
    }

    func cancelDeleteTake() {
        takePendingDeletion = nil
    }

    func confirmDeleteTake() {
        guard let take = takePendingDeletion else {
            return
        }
        takePendingDeletion = nil
        pauseComparisonPlaybackIfNeeded()
        Task { [weak self] in
            await self?.deleteTake(take)
        }
    }

    func refreshTakes() async {
        guard let recordingDependencies else {
            takes = []
            return
        }
        do {
            takes = try await recordingDependencies.takes.takes(projectID: project.id)
                .sorted { $0.sequence < $1.sequence }
        } catch {
            show(error)
        }
    }

    private func deleteTake(_ take: Take) async {
        guard let recordingDependencies else {
            show(PracticeRecordingError.unavailable)
            return
        }
        do {
            try await recordingDependencies.takes.deleteTake(id: take.id)
            do {
                try recordingDependencies.fileStore.deleteAudio(
                    relativePath: take.relativeAudioPath
                )
            } catch {
                show(error)
            }
            await refreshTakes()
            if let next = takes.max(by: { $0.createdAt < $1.createdAt }) {
                selectedTakePeaks = []
                await enterComparison(with: next, takePeaks: [])
            } else {
                activeTake = nil
                selectedTakePeaks = []
                project.selectedTakeID = nil
                recordingPresentation = .idle
                interactionPhase = .practicing
                recordingNotice = nil
                do {
                    try await projects.save(project)
                } catch {
                    show(error)
                }
            }
        } catch {
            show(error)
        }
    }

    private func pauseComparisonPlaybackIfNeeded() {
        guard isPlaying else {
            return
        }
        performVoidCommand { [audioClient] in
            try await audioClient.execute(.pause)
        } completion: { [weak self] in
            self?.isPlaying = false
        }
    }

    private func updateRegionSnapshotNotice(for take: Take) {
        if let currentRegion = project.currentRegion, take.region != currentRegion {
            recordingNotice = comparisonRegionNotice
        } else if recordingNotice?.contains("recorded region") == true {
            recordingNotice = nil
        }
    }

    private func persistSelectedTake() {
        persistProjectImmediately()
    }

    private func peaks(for region: PracticeRegion) -> [Float] {
        guard project.duration > 0, !waveform.peaks.isEmpty else {
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
}
