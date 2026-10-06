import Foundation

/// A running "Compare": the sentence it is pinned to and the steps still to play.
struct ComparisonPlayback: Equatable, Sendable {
    let sentence: SentenceChunk
    let source: SentenceSource
    let takeID: UUID?
    let mode: CompareMode
    /// Playhead to restore when Compare ends or is stopped (selection/loop stay untouched).
    let restoredPlayhead: TimeInterval
    var remaining: [CompareStep]
    var current: CompareStep?
}

extension PracticeViewModel {
    /// The take Compare uses while playing, else the selected one, else the newest.
    var compareTake: Take? {
        if let id = comparison?.takeID, let take = takes.first(where: { $0.id == id }) {
            return take
        }
        if let active = activeTake, let take = takes.first(where: { $0.id == active.id }) {
            return take
        }
        return takes.first
    }

    func alignmentOffset(for takeID: UUID) -> TimeInterval {
        takeOffsets[takeID] ?? 0
    }

    func setCompareMode(_ mode: CompareMode) {
        compareMode = mode
    }

    /// C: play the current sentence as the original, mine, or the original then mine.
    /// Pressing C again while comparing stops. Does not change selection, playhead, or loop:
    /// while `comparison != nil` engine playhead/end events never reach the main playhead.
    func compare() {
        if comparison != nil {
            stopComparison()
            return
        }
        guard !controlsLocked, let (sentence, source) = currentSentenceWithSource else {
            return
        }
        beginComparison(sentence: sentence, source: source, take: compareTake)
    }

    /// The "Compare" action on a take row. Uses that take for Compare playback only —
    /// does not change selection, playhead, or loop (unlike list-click `selectTake`).
    func compare(with take: Take) {
        guard take.projectID == project.id, !controlsLocked else {
            return
        }
        if comparison != nil {
            stopComparison()
        }
        guard let (sentence, source) = currentSentenceWithSource else {
            return
        }
        beginComparison(sentence: sentence, source: source, take: take)
    }

    /// Starts Compare for `take` without going through `selectTake`.
    private func beginComparison(sentence: SentenceChunk, source: SentenceSource, take: Take?) {
        let steps = ComparePlanner.steps(
            sentence: sentence,
            sourceDuration: project.duration,
            take: take,
            offset: take.map { alignmentOffset(for: $0.id) } ?? 0,
            mode: compareMode
        )
        guard !steps.isEmpty else {
            return
        }
        pauseTakePlaybackIfNeeded()
        restoringPlayheadAfterComparison = nil
        comparison = ComparisonPlayback(
            sentence: sentence,
            source: source,
            takeID: take?.id,
            mode: compareMode,
            restoredPlayhead: playhead,
            remaining: steps
        )
        playNextCompareStep()
    }

    func playNextCompareStep() {
        guard var playback = comparison else {
            return
        }
        guard !playback.remaining.isEmpty else {
            finishComparison()
            return
        }
        let step = playback.remaining.removeFirst()
        playback.current = step
        comparison = playback
        // The main playhead is not touched here: it stays frozen for the whole Compare.
        let command: PracticeAudioCommand
        switch step {
        case let .original(region):
            playingTakeID = nil
            command = .playOriginalSegment(region: region, from: region.start, rate: rate)
        case let .take(id, region):
            playingTakeID = id
            command = .playTakeSegment(takeID: id, region: region)
        }
        performCommand { [audioClient] in
            try await audioClient.execute(command)
            return true
        } completion: { [weak self] playing in
            self?.isPlaying = playing
        }
    }

    /// Called for `segmentFinished`; returns false when no comparison is running.
    /// `isPlaying` stays true across the gap between steps: Compare is still playing.
    func handleCompareSegmentFinished() -> Bool {
        guard let playback = comparison else {
            return false
        }
        guard !playback.remaining.isEmpty else {
            finishComparison()
            return true
        }
        Task { [weak self, comparisonScheduler] in
            try? await comparisonScheduler.waitForABGap()
            guard let self, comparison == playback else {
                return
            }
            playNextCompareStep()
        }
        return true
    }

    func finishComparison() {
        guard let playback = comparison else {
            return
        }
        comparison = nil
        playingTakeID = nil
        isPlaying = false
        restorePlayheadAfterComparison(playback)
    }

    func stopComparison() {
        cancelComparison()
        performVoidCommand { [audioClient] in
            try await audioClient.execute(.pause)
        }
    }

    /// Transport intents end a comparison; volume changes do not.
    func cancelComparison(for intent: PracticeIntent) {
        if intent.requiresUnlockedTransport {
            cancelComparison()
        }
    }

    /// Ends the running comparison and restores the playhead (engine included).
    /// Selection and loop are unchanged. Callers that issue another audio command next
    /// still get a correct engine position if that command never seeks.
    func cancelComparison() {
        guard let playback = comparison else {
            return
        }
        comparison = nil
        playingTakeID = nil
        // Clear before async pause/seek so Space (C then Space) plays from restored, never pauses.
        isPlaying = false
        restorePlayheadAfterComparison(playback)
    }

    /// Syncs ViewModel + project playhead and seeks the audio engine to the pre-Compare position.
    private func restorePlayheadAfterComparison(_ playback: ComparisonPlayback) {
        let restored = playback.restoredPlayhead
        playhead = restored
        project.playhead = restored
        restoringPlayheadAfterComparison = restored
        performVoidCommand { [audioClient] in
            try await audioClient.execute(.seek(restored))
        } completion: { [weak self] in
            guard let self else {
                return
            }
            // Drop the gate only for this restore; do not clobber a newer seek/playhead.
            if restoringPlayheadAfterComparison == restored {
                restoringPlayheadAfterComparison = nil
            }
        }
    }

    // MARK: - Alignment offsets

    func saveAlignmentOffset(_ offset: TimeInterval) {
        guard let context = recordingContext else {
            return
        }
        let offset = RecordingAlignment.clamped(offset)
        takeOffsets[context.id] = offset
        guard let alignment = recordingDependencies?.alignment else {
            return
        }
        // Persist before recordingFinished → refreshTakes → loadTakeOffsets can race a missing sidecar.
        try? alignment.saveOffset(offset, for: context.id)
    }

    func loadTakeOffsets() async {
        guard let alignment = recordingDependencies?.alignment else {
            return
        }
        let ids = takes.map(\.id)
        let loaded = await Task.detached(priority: .utility) {
            Dictionary(uniqueKeysWithValues: ids.map { ($0, alignment.offset(for: $0)) })
        }.value
        takeOffsets = loaded
    }
}

extension PracticeViewModel {
    var comparisonRegionNotice: String? {
        guard let take = activeTake,
              let currentRegion = project.currentRegion,
              take.region != currentRegion
        else {
            return nil
        }
        return Self.regionSnapshotNotice(for: take)
    }

    /// Shown when the selected take was recorded over a different region than the current one.
    static func regionSnapshotNotice(for take: Take) -> String {
        let start = ClockText.format(take.region.start)
        let end = ClockText.format(take.region.end)
        return String(localized: """
        This take keeps its recorded region (\(start)–\(end)). \
        Changing the practice region does not change past takes.
        """)
    }
}
