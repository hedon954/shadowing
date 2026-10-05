import Foundation

/// Where the sentence under the playhead comes from, in priority order.
enum SentenceSource: Equatable, Sendable {
    /// The loop range the user selected on the waveform.
    case loopRange
    /// Timed subtitles (a subtitle file, aligned text or speech recognition).
    case subtitles
    /// Pauses in the original audio.
    case pauses
}

extension PracticeViewModel {
    var timedCues: [SubtitleCue] {
        if case let .timed(transcript) = subtitles.display {
            return transcript.cues
        }
        return []
    }

    /// The sentence that Return replays and C compares: the loop range, else the subtitle cue
    /// under the playhead, else the pause chunk under the playhead.
    var currentSentence: SentenceChunk? {
        currentSentenceWithSource?.chunk
    }

    var currentSentenceWithSource: (chunk: SentenceChunk, source: SentenceSource)? {
        if let pinned = comparison?.sentence {
            return (pinned, comparison?.source ?? .pauses)
        }
        return sentence(at: playhead)
    }

    func sentence(at time: TimeInterval) -> (chunk: SentenceChunk, source: SentenceSource)? {
        if let region {
            return (SentenceChunk(start: region.start, end: region.end), .loopRange)
        }
        let cues = timedCues
        if !cues.isEmpty {
            let index = SubtitleTimeline.cueIndex(at: time, in: cues) ?? 0
            let cue = cues[index]
            return (SentenceChunk(start: cue.start, end: max(cue.end, cue.start + 0.2)), .subtitles)
        }
        guard let chunk = PauseSegmenter.chunk(at: time, in: sentenceChunks) else {
            return nil
        }
        return (chunk, .pauses)
    }

    /// The subtitle line for the one-line caption under the waveforms.
    var currentCaption: SubtitleCue? {
        let cues = timedCues
        guard !cues.isEmpty, let index = SubtitleTimeline.cueIndex(at: playhead, in: cues) ?? cues.indices.first else {
            return nil
        }
        return cues[index]
    }

    func loadSentenceChunks() {
        let projectID = project.id
        let waveform = waveform
        Task { [weak self, pauseChunks] in
            let chunks = await pauseChunks.chunks(projectID: projectID, waveform: waveform)
            self?.sentenceChunks = chunks
        }
    }

    /// Return: play the current sentence of the original once, from its start.
    func replayCurrentSentence() {
        guard !controlsLocked, let sentence = currentSentence,
              let region = sentence.region(sourceDuration: project.duration)
        else {
            return
        }
        cancelComparison()
        pauseTakePlaybackIfNeeded()
        playingTakeID = nil
        playhead = region.start
        performCommand { [audioClient, rate] in
            try await audioClient.execute(.playOriginalSegment(region: region, from: region.start, rate: rate))
            return true
        } completion: { [weak self] playing in
            self?.isPlaying = playing
        }
    }
}

extension PracticeViewModel {
    /// ⌘[ / ⌘]: one step through the supported speeds.
    func stepRate(faster: Bool) {
        let rates = Self.supportedRates
        guard let index = rates.firstIndex(of: rate) ?? rates.firstIndex(of: 1) else {
            return
        }
        let next = min(max(index + (faster ? 1 : -1), 0), rates.count - 1)
        setRate(rates[next])
    }
}
