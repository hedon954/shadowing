import Foundation

extension PracticeViewModel {
    func regionCommand(_ intent: PracticeIntent) {
        switch intent {
        case let .selectRegion(region):
            selectRegionCommand(region)
        case let .resizeRegion(region):
            resizeRegionCommand(region)
        case .clearRegion:
            clearRegionCommand()
        default:
            break
        }
    }

    func selectRegionCommand(_ region: PracticeRegion) {
        guard region.end <= project.duration else {
            show(DomainError.invalidTimeRange)
            return
        }
        project.currentRegion = region
        loopEnabled = true
        let resumeInsideLoop = isPlaying
            && playingTakeID == nil
            && playhead >= region.start
            && playhead < region.end
        let nextPlayhead = resumeInsideLoop ? playhead : region.start
        playhead = nextPlayhead
        project.playhead = nextPlayhead
        syncTakePlayheads(toSourceTime: nextPlayhead)
        pendingLocalSeek = nextPlayhead
        // Released from a waveform drag: the release reveal aims at where playback continues
        // (this selection and its start), never at the playhead it is about to leave.
        _ = deferTimelineMoveDuringGesture(focus: region)
        performVoidCommand(seekGate: nextPlayhead) { [audioClient] in
            try await audioClient.execute(.setLoop(region))
            try await audioClient.execute(.seek(nextPlayhead))
        } completion: { [weak self] in
            self?.persistProjectImmediately()
        }
    }

    func clearRegionCommand() {
        guard region != nil else {
            return
        }
        project.currentRegion = nil
        loopEnabled = false
        performVoidCommand { [audioClient] in
            try await audioClient.execute(.setLoop(nil))
        } completion: { [weak self] in
            self?.persistProjectImmediately()
        }
    }

    /// The selection's edge was dragged: only the selection changes. The loop never turns on
    /// here; one that is on follows the new range. The playhead stays where it is (like after
    /// a click, the engine plays into the loop from before it, or straight on from after it).
    func resizeRegionCommand(_ region: PracticeRegion) {
        guard region.end <= project.duration else {
            show(DomainError.invalidTimeRange)
            return
        }
        project.currentRegion = region
        guard loopEnabled else {
            persistProjectImmediately()
            return
        }
        performVoidCommand { [audioClient] in
            try await audioClient.execute(.setLoop(region))
        } completion: { [weak self] in
            self?.persistProjectImmediately()
        }
    }
}
