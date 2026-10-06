import Foundation

extension PracticeViewModel {
    var comparisonOriginalPeaks: [Float] {
        guard let take = activeTake else {
            return originalRecordingRegionPeaks
        }
        return peaks(for: take.region)
    }

    var selectedTakeWaveform: WaveformPresentation {
        guard let id = activeTake?.id else {
            return .unavailable
        }
        return takeWaveforms[id] ?? .unavailable
    }

    var isCurrentTakeKept: Bool {
        guard let take = activeTake else {
            return false
        }
        return project.keptTakeID == take.id
    }

    /// Select a take for comparing / delete without changing page layout.
    func focusTake(_ take: Take, preferExistingViewport: Bool = false) async {
        pauseTakePlaybackIfNeeded()
        activeTake = take
        project.selectedTakeID = take.id
        if !preferExistingViewport {
            playhead = take.region.start
            project.playhead = take.region.start
            if !deferTimelineMoveDuringGesture(focus: take.region) {
                timelineViewport = .fitting(
                    take.region,
                    sourceDuration: project.duration
                )
            }
            revealPlayhead(focus: take.region)
        }
        await refreshTakes()
        updateRegionSnapshotNotice(for: take)
        do {
            try await projects.save(project)
        } catch {
            show(error)
        }
    }

    /// Select a take, jump the playhead to its start, and sync the practice selection to
    /// that take's interval. Does not start playback, and does not change loop on/off.
    /// Stops Compare first if it is running. Always seeks to the take start — even when
    /// original audio or Compare was playing with the playhead already inside the region.
    func selectTake(_ take: Take) {
        guard take.projectID == project.id else {
            return
        }
        if comparison != nil {
            stopComparison()
        }
        pauseTakePlaybackIfNeeded()
        // Clear playing flags synchronously so a following seek is never gated on a stale
        // isPlaying that pauseTakePlaybackIfNeeded only clears in its async completion.
        playingTakeID = nil
        isPlaying = false
        if activeTake?.id != take.id {
            activeTake = take
            project.selectedTakeID = take.id
            selectedTakePeaks = takeWaveforms[take.id]?.peaks ?? []
            Task { [weak self] in
                await self?.loadTakeWaveform(for: take)
            }
        }
        // Mirror the take interval on the waveform selection without turning loop on.
        project.currentRegion = take.region
        let shouldUpdateLoop = loopEnabled
        // Always force the playhead to the take start (Designer: click take → jump); the takes'
        // own playheads follow it, so the play button starts where the screen shows.
        playhead = take.region.start
        project.playhead = take.region.start
        syncTakePlayheads(toSourceTime: take.region.start)
        revealPlayhead(focus: take.region)
        performVoidCommand { [audioClient] in
            if shouldUpdateLoop {
                try await audioClient.execute(.setLoop(take.region))
            }
            try await audioClient.execute(.seek(take.region.start))
        } completion: { [weak self] in
            self?.persistProjectImmediately()
        }
        updateRegionSnapshotNotice(for: take)
    }

    func clearTakeSelection() {
        guard activeTake != nil else {
            return
        }
        // Deselecting stops a playing take, never the original (a waveform click lands here).
        if playingTakeID != nil {
            pauseTakePlaybackIfNeeded()
        }
        activeTake = nil
        project.selectedTakeID = nil
        selectedTakePeaks = []
        recordingNotice = nil
        persistProjectImmediately()
    }

    func keepThisTake() {
        guard let take = activeTake else {
            return
        }
        project.keptTakeID = take.id
        persistProjectImmediately()
    }

    /// Reorders Take tracks under Original. Labels (`sequence`) stay unchanged.
    func reorderTakes(draggedID: UUID, onto targetID: UUID) {
        guard isInteractiveForTakeReorder,
              let reordered = try? TakeDisplayOrdering.moving(
                  takes,
                  draggedID: draggedID,
                  onto: targetID
              )
        else {
            return
        }
        takes = reordered
        Task { [weak self] in
            await self?.persistTakeOrder(reordered)
        }
    }

    private var isInteractiveForTakeReorder: Bool {
        !controlsLocked && takes.count > 1
    }

    private func persistTakeOrder(_ orderedTakes: [Take]) async {
        guard let recordingDependencies else {
            return
        }
        do {
            try await recordingDependencies.takes.reorderTakes(orderedTakes)
            // A deleted take's old position may now belong to another take; its Undo would fail.
            forgetUndoDelete()
        } catch {
            show(error)
            await refreshTakes()
        }
    }

    func refreshTakes() async {
        guard let recordingDependencies else {
            takes = []
            return
        }
        do {
            takes = try await recordingDependencies.takes.takes(projectID: project.id)
                .sorted {
                    if $0.displayOrder == $1.displayOrder {
                        return $0.sequence < $1.sequence
                    }
                    return $0.displayOrder < $1.displayOrder
                }
            let ids = Set(takes.map(\.id))
            takeWaveforms = takeWaveforms.filter { ids.contains($0.key) }
            takeLoopSelections = takeLoopSelections.filter { ids.contains($0.key) }
            takePlayheads = takePlayheads.filter { ids.contains($0.key) }
            await loadTakeOffsets()
        } catch {
            show(error)
        }
    }

    func preloadTakeWaveforms() async {
        for take in takes where takeWaveforms[take.id] == nil {
            await loadTakeWaveform(for: take)
        }
    }

    func pauseTakePlaybackIfNeeded() {
        guard playingTakeID != nil || isPlaying else {
            return
        }
        settleTakePlayheadsAfterPlaybackStopped() // the playback stops here, on screen
        let wasTake = playingTakeID != nil
        playingTakeID = nil
        guard isPlaying || wasTake else {
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
            recordingNotice = Self.regionSnapshotNotice(for: take)
        } else if takes.contains(where: { recordingNotice == Self.regionSnapshotNotice(for: $0) }) {
            recordingNotice = nil
        }
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

    func currentlyPlayingTake() -> Take? {
        guard let takeID = playingTakeID else {
            return nil
        }
        return takes.first(where: { $0.id == takeID }) ?? activeTake
    }
}
