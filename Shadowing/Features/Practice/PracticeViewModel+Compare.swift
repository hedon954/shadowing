import Foundation

/// A running "Compare": the sentence it is pinned to and the steps still to play.
struct ComparisonPlayback: Equatable, Sendable {
    let sentence: SentenceChunk
    let source: SentenceSource
    let takeID: UUID?
    let mode: CompareMode
    var remaining: [CompareStep]
    var current: CompareStep?
}

extension PracticeViewModel {
    /// The take Compare uses: the selected one, else the newest.
    var compareTake: Take? {
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
    /// Pressing C again while comparing stops.
    func compare() {
        if comparison != nil {
            stopComparison()
            return
        }
        guard !controlsLocked, let (sentence, source) = currentSentenceWithSource else {
            return
        }
        let take = compareTake
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
        if let take, activeTake?.id != take.id {
            selectTake(take)
        }
        pauseTakePlaybackIfNeeded()
        comparison = ComparisonPlayback(
            sentence: sentence,
            source: source,
            takeID: take?.id,
            mode: compareMode,
            remaining: steps
        )
        playNextCompareStep()
    }

    /// The "Compare" action on a take row.
    func compare(with take: Take) {
        cancelComparison()
        selectTake(take)
        compare()
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
        let command: PracticeAudioCommand
        switch step {
        case let .original(region):
            playingTakeID = nil
            playhead = region.start
            command = .playOriginalSegment(region: region, from: region.start, rate: rate)
        case let .take(id, region):
            playingTakeID = id
            playhead = playback.sentence.start
            command = .playTakeSegment(takeID: id, region: region)
        }
        performCommand { [audioClient] in
            try await audioClient.execute(command)
            return true
        } completion: { [weak self] playing in
            self?.isPlaying = playing
        }
    }

    /// Called for `playbackFinished`; returns false when no comparison is running.
    func handleComparePlaybackFinished() -> Bool {
        guard let playback = comparison else {
            return false
        }
        isPlaying = false
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
        playhead = playback.sentence.start
    }

    func stopComparison() {
        cancelComparison()
        performVoidCommand { [audioClient] in
            try await audioClient.execute(.pause)
        } completion: { [weak self] in
            self?.isPlaying = false
        }
    }

    /// Transport intents end a comparison; volume changes do not.
    func cancelComparison(for intent: PracticeIntent) {
        if intent.requiresUnlockedTransport {
            cancelComparison()
        }
    }

    /// Forgets the running comparison without touching the audio (another command follows).
    func cancelComparison() {
        guard comparison != nil else {
            return
        }
        comparison = nil
        playingTakeID = nil
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
        let takeID = context.id
        Task.detached(priority: .utility) {
            try? alignment.saveOffset(offset, for: takeID)
        }
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
