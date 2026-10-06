import Foundation

/// A take's own transport: its play button, its loop selection, and clicks on its lane.
///
/// Each take keeps its own playhead (`takePlayheads`, take-file time, in memory only): set by
/// a click on its lane, by its playback progress, and by choosing its loop; cleared when its
/// playback reaches the end. Its play button starts there, and from its loop start (or 0)
/// only when it has none. The loop never moves the playhead: from before the loop the take
/// plays into it and then loops; from after it, straight on to the take's end.
///
/// Waveform (source) time and take-file time convert with the take's measured offset
/// (`RecordingAlignment`), both ways, so the playhead never jumps by the offset.
extension PracticeViewModel {
    func toggleTakePlayback(_ take: Take) {
        cancelComparison()
        // A take that has played all its audio is finished, even while the engine's end
        // callback (after the output latency) is still on its way: the press plays it again.
        if playingTakeID == take.id, isPlaying, !takePlaybackReachedEnd {
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
        let localLoop = takeLocalLoop(take)
        let from = resumableTakePlayhead(take) ?? localLoop?.start ?? 0
        let target = moveTakePlayhead(take, to: from)
        playingTakeID = take.id
        focusTimelineForTakePlayback(take)
        playTake(take, from: from, loop: localLoop, seekGate: target)
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
        let localLoop = takeLocalLoop(take)
        // Choosing a loop moves the take's playhead into it (like selecting on the original),
        // unless it is already inside. A click never does this; see `seekTakeLane`.
        let local = takeTime(take, forSourceTime: playhead)
        let localFrom = localLoop.map { $0.start ..< $0.end ~= local ? local : $0.start } ?? local
        let target = moveTakePlayhead(take, to: localFrom)
        if playingTakeID == take.id, isPlaying, let localLoop {
            playTake(take, from: localFrom, loop: localLoop, seekGate: target)
        } else {
            persistProjectImmediately()
        }
    }

    func clearTakeLoopRegion(_ take: Take) {
        takeLoopSelections[take.id] = nil
        guard playingTakeID == take.id, isPlaying else {
            return
        }
        let localFrom = takeTime(take, forSourceTime: playhead)
        let target = moveTakePlayhead(take, to: localFrom)
        playTake(take, from: localFrom, loop: nil, seekGate: target)
    }

    /// A single click on a take lane (Designer rule). While this same take plays it keeps
    /// playing from the click spot, like the original does. Any other case keeps the usual
    /// click rules (`seekTimeline`): a playing take on another lane stops and the playhead
    /// moves there, paused, so a click never starts a different sound; during Compare the
    /// Compare rules apply unchanged. Either way the click becomes the take's playhead (see
    /// `syncTakePlayheads`), so its play button starts there.
    func seekTakeLane(_ take: Take, to sourceTime: TimeInterval) {
        guard comparison == nil, !controlsLocked else {
            seekTimeline(sourceTime)
            return
        }
        guard playingTakeID == take.id, isPlaying else {
            seekTimeline(sourceTime) // also sets the takes' playheads there
            return
        }
        let localFrom = takeTime(take, forSourceTime: sourceTime)
        // The take's loop selection stays, even for a click outside it, and the playhead goes
        // exactly where clicked: the engine plays into the loop from before it, or straight
        // on to the take's end from after it.
        let target = moveTakePlayhead(take, to: localFrom)
        playTake(take, from: localFrom, loop: takeLocalLoop(take), seekGate: target)
    }

    func handleTakePlaybackFinished() {
        isPlaying = false
        takePlaybackReachedEnd = false
        if let take = currentlyPlayingTake() {
            playhead = take.region.end
            project.playhead = playhead
            // Other takes follow the playhead; this one reached its end, so its next play
            // starts again from its loop start (or 0).
            syncTakePlayheads(toSourceTime: playhead)
            takePlayheads[take.id] = nil
        }
        playingTakeID = nil
        persistProjectImmediately()
    }

    /// A take position the engine reported while it plays: it moves the playhead and becomes
    /// the take's own playhead.
    func takePlaybackProgressed(_ take: Take, to position: TimeInterval) {
        let local = min(max(position, 0), max(take.duration, 0))
        takePlayheads[take.id] = keptTakePlayhead(take, local)
        takePlaybackReachedEnd = local >= take.duration - Self.takeEndReachedTolerance
        playhead = takeSourcePlayhead(take, forTakeTime: local)
    }

    /// The user moved the playhead to `sourceTime` (a click on any lane, a sentence, a take
    /// row, a selection, a jump): every take whose span holds it takes that spot as its own
    /// playhead; every other take loses its playhead, so its play button starts from its loop
    /// start (or 0). Play always starts from the playhead on screen. Engine positions never
    /// come here (only the playing take follows them, and only with the seek gate open).
    func syncTakePlayheads(toSourceTime sourceTime: TimeInterval) {
        for take in takes {
            let inside = take.region.start ..< take.region.end ~= sourceTime
            takePlayheads[take.id] = inside ? keptTakePlayhead(take, takeTime(take, forSourceTime: sourceTime)) : nil
        }
    }

    /// Playback stopped (pause, Space, the end, a sentence replay ending, Compare restoring,
    /// an interruption), the original's or a take's: every take's playhead follows where it
    /// settled, so any take's play button starts at the paused playhead on screen. Call it
    /// once per stop and before `playingTakeID` is cleared; a pending seek's target wins
    /// over any engine position. The take that played keeps its own exact spot.
    func settleTakePlayheadsAfterPlaybackStopped() {
        let stopped = currentlyPlayingTake()
        let own = stopped.flatMap { takePlayheads[$0.id] }
        syncTakePlayheads(toSourceTime: pendingLocalSeek ?? playhead)
        if let stopped {
            takePlayheads[stopped.id] = keptTakePlayhead(stopped, own)
        }
    }

    /// Take-file time for a waveform time, with the take's offset, kept inside the file.
    func takeTime(_ take: Take, forSourceTime sourceTime: TimeInterval) -> TimeInterval {
        let local = RecordingAlignment.takeTime(
            forSourceTime: sourceTime,
            regionStart: take.region.start,
            offset: alignmentOffset(for: take.id)
        )
        return min(max(local, 0), max(take.duration, 0))
    }

    /// The waveform playhead for a take-file time, with the take's offset, on its lane.
    func takeSourcePlayhead(_ take: Take, forTakeTime local: TimeInterval) -> TimeInterval {
        let source = RecordingAlignment.sourceTime(
            forTakeTime: local,
            regionStart: take.region.start,
            offset: alignmentOffset(for: take.id)
        )
        return min(max(source, take.region.start), take.region.end)
    }

    /// The take's loop selection in take-file time.
    func takeLocalLoop(_ take: Take) -> PracticeRegion? {
        takeLoopSelections[take.id].flatMap { selection in
            TakePlaybackTiming.localLoopRegion(
                selection: selection,
                takeRegion: take.region,
                offset: alignmentOffset(for: take.id)
            )
        }
    }

    /// The take's own playhead, unless it has none yet or it is at the take's end.
    private func resumableTakePlayhead(_ take: Take) -> TimeInterval? {
        keptTakePlayhead(take, takePlayheads[take.id])
    }

    /// A take playhead less than this before the take's end (in the take's own time, after
    /// the offset) counts as finished, so Play does not start a tiny blip at the end.
    static let takeEndFinishThreshold: TimeInterval = 0.5

    /// The engine reports a take that played all its audio at the take's full length; this
    /// allows for the saved length differing from the file by a few milliseconds.
    static let takeEndReachedTolerance: TimeInterval = 0.05

    /// The one rule for every take playhead: `local` (take time) is kept unless it is less
    /// than `takeEndFinishThreshold` before the take's end; then nil, so the take's Play
    /// starts from its loop start (or 0). Same for any offset, as `local` already has it.
    func keptTakePlayhead(_ take: Take, _ local: TimeInterval?) -> TimeInterval? {
        guard let local, local < take.duration - Self.takeEndFinishThreshold else {
            return nil
        }
        return local
    }

    /// Sets the take's playhead and the waveform playhead; returns the waveform target.
    private func moveTakePlayhead(_ take: Take, to local: TimeInterval) -> TimeInterval {
        let target = takeSourcePlayhead(take, forTakeTime: local)
        syncTakePlayheads(toSourceTime: target)
        takePlayheads[take.id] = keptTakePlayhead(take, local) // exact, also off the lane
        playhead = target
        project.playhead = target
        return target
    }

    // Plays the take from `local`. `seekGate` (the waveform target) stays closed until the
    // take restarts there, so positions it reports from before cannot pull the playhead
    // back; it is released on every exit.

    private func playTake(
        _ take: Take,
        from local: TimeInterval,
        loop: PracticeRegion?,
        seekGate: TimeInterval
    ) {
        playingTakeID = take.id
        takePlaybackReachedEnd = false
        pendingLocalSeek = seekGate
        performCommand(seekGate: seekGate) { [audioClient] in
            try await audioClient.execute(.playTake(takeID: take.id, from: local, loop: loop))
            return true
        } completion: { [weak self] playing in
            self?.isPlaying = playing
            if !playing {
                self?.playingTakeID = nil
            }
        }
    }
}
