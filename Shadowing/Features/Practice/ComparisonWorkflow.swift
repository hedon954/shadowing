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

    /// Select a take for overwrite / delete without changing page layout.
    func focusTake(_ take: Take, preferExistingViewport: Bool = false) async {
        pauseTakePlaybackIfNeeded()
        activeTake = take
        project.selectedTakeID = take.id
        if !preferExistingViewport {
            playhead = take.region.start
            project.playhead = take.region.start
            timelineViewport = .fitting(
                take.region,
                sourceDuration: project.duration
            )
        }
        await refreshTakes()
        updateRegionSnapshotNotice(for: take)
        do {
            try await projects.save(project)
        } catch {
            show(error)
        }
    }

    func selectTake(_ take: Take) {
        guard take.projectID == project.id else {
            return
        }
        if activeTake?.id == take.id {
            return
        }
        pauseTakePlaybackIfNeeded()
        activeTake = take
        project.selectedTakeID = take.id
        selectedTakePeaks = takeWaveforms[take.id]?.peaks ?? []
        Task { [weak self] in
            await self?.loadTakeWaveform(for: take)
        }
        // Keep the Original-timeline playhead where it is so overwrite recording
        // still starts from the user's current cursor (PRD §10.6).
        updateRegionSnapshotNotice(for: take)
        persistProjectImmediately()
    }

    func clearTakeSelection() {
        guard activeTake != nil else {
            return
        }
        pauseTakePlaybackIfNeeded()
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

    func toggleTakePlayback(_ take: Take) {
        if playingTakeID == take.id, isPlaying {
            pauseTakePlaybackIfNeeded()
            return
        }
        pauseTakePlaybackIfNeeded()
        if isPlaying {
            performVoidCommand { [audioClient] in
                try await audioClient.execute(.pause)
            } completion: { [weak self] in
                self?.isPlaying = false
            }
        }
        if activeTake?.id != take.id {
            activeTake = take
            project.selectedTakeID = take.id
            selectedTakePeaks = takeWaveforms[take.id]?.peaks ?? []
            Task { [weak self] in
                await self?.loadTakeWaveform(for: take)
            }
            persistProjectImmediately()
        }
        playhead = take.region.start
        project.playhead = take.region.start
        playingTakeID = take.id
        let localLoop = takeLoopSelections[take.id].flatMap { selection in
            TakePlaybackTiming.localLoopRegion(
                selection: selection,
                takeRegion: take.region
            )
        }
        let from = localLoop?.start ?? 0
        if let localLoop {
            playhead = take.region.start + localLoop.start
            project.playhead = playhead
        }
        focusTimelineForTakePlayback(take)
        performCommand { [audioClient] in
            try await audioClient.execute(
                .playTake(takeID: take.id, from: from, loop: localLoop)
            )
            return true
        } completion: { [weak self] playing in
            self?.isPlaying = playing
            if !playing {
                self?.playingTakeID = nil
            }
        }
    }

    func selectTakeLoopRegion(_ take: Take, _ region: PracticeRegion) {
        guard take.projectID == project.id else {
            return
        }
        guard let clamped = TakePlaybackTiming.clampedSelection(
            region,
            takeRegion: take.region,
            sourceDuration: project.duration
        ) else {
            return
        }
        if activeTake?.id != take.id {
            activeTake = take
            project.selectedTakeID = take.id
            selectedTakePeaks = takeWaveforms[take.id]?.peaks ?? []
            Task { [weak self] in
                await self?.loadTakeWaveform(for: take)
            }
        }
        takeLoopSelections[take.id] = clamped
        let localLoop = TakePlaybackTiming.localLoopRegion(
            selection: clamped,
            takeRegion: take.region
        )
        let localFrom = takeLocalPlaybackPosition(take: take, localLoop: localLoop)
        playhead = take.region.start + localFrom
        project.playhead = playhead
        if playingTakeID == take.id, isPlaying, let localLoop {
            playingTakeID = take.id
            performCommand { [audioClient] in
                try await audioClient.execute(
                    .playTake(takeID: take.id, from: localFrom, loop: localLoop)
                )
                return true
            } completion: { [weak self] playing in
                self?.isPlaying = playing
                if !playing {
                    self?.playingTakeID = nil
                }
            }
        } else {
            persistProjectImmediately()
        }
    }

    func clearTakeLoopRegion(_ take: Take) {
        takeLoopSelections[take.id] = nil
        guard playingTakeID == take.id, isPlaying else {
            return
        }
        let localFrom = takeLocalPlaybackPosition(take: take, localLoop: nil)
        playhead = take.region.start + localFrom
        project.playhead = playhead
        performCommand { [audioClient] in
            try await audioClient.execute(
                .playTake(takeID: take.id, from: localFrom, loop: nil)
            )
            return true
        } completion: { [weak self] playing in
            self?.isPlaying = playing
            if !playing {
                self?.playingTakeID = nil
            }
        }
    }

    private func takeLocalPlaybackPosition(
        take: Take,
        localLoop: PracticeRegion?
    ) -> TimeInterval {
        let local = min(
            max(playhead - take.region.start, 0),
            max(take.duration, 0)
        )
        guard let localLoop else {
            return local
        }
        if local >= localLoop.start, local < localLoop.end {
            return local
        }
        return localLoop.start
    }

    func handleTakePlaybackFinished() {
        isPlaying = false
        if let take = currentlyPlayingTake() {
            playhead = take.region.end
            project.playhead = playhead
        }
        playingTakeID = nil
        persistProjectImmediately()
    }

    func requestDeleteTake(_ take: Take? = nil) {
        guard let target = take ?? activeTake else {
            return
        }
        pauseTakePlaybackIfNeeded()
        Task { [weak self] in
            await self?.deleteTake(target)
        }
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
        } catch {
            show(error)
        }
    }

    func preloadTakeWaveforms() async {
        for take in takes where takeWaveforms[take.id] == nil {
            await loadTakeWaveform(for: take)
        }
    }

    func deleteTake(_ take: Take) async {
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
            takeWaveforms[take.id] = nil
            takeLoopSelections[take.id] = nil
            if project.keptTakeID == take.id {
                project.keptTakeID = nil
            }
            if playingTakeID == take.id {
                playingTakeID = nil
                isPlaying = false
            }
            await refreshTakes()
            if let next = takes.max(by: { $0.createdAt < $1.createdAt }) {
                await focusTake(next, preferExistingViewport: true)
                await loadTakeWaveform(for: next)
            } else {
                activeTake = nil
                selectedTakePeaks = []
                project.selectedTakeID = nil
                recordingNotice = nil
                playhead = min(max(project.playhead, 0), project.duration)
                if let region {
                    timelineViewport = .fitting(
                        region,
                        sourceDuration: project.duration
                    )
                } else {
                    timelineViewport = .full(sourceDuration: project.duration)
                }
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

    func pauseTakePlaybackIfNeeded() {
        guard playingTakeID != nil || isPlaying else {
            return
        }
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
            recordingNotice = """
            This take keeps its recorded region \
            (\(Self.formatTime(take.region.start))–\(Self.formatTime(take.region.end))). \
            Changing the practice region does not change past takes.
            """
        } else if recordingNotice?.contains("recorded region") == true {
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
