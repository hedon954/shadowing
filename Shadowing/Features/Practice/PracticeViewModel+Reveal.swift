import Foundation
import SwiftUI

/// The one rule for when the zoomed waveform and the full transcript move to the playhead.
///
/// Every active jump (clicking a take or a sentence, dragging the playhead, opening a project)
/// bumps `token`; both views reveal the playhead on each bump, also when paused. Only the
/// user's own transcript scrolling pauses auto-follow during playback, for
/// `TranscriptLineEmphasis.manualScrollPause`. A reveal never starts that pause, and clears it.
struct JumpReveal: Equatable, Sendable {
    private(set) var token = 0
    private(set) var userScrolledAt: Date?

    mutating func reveal() {
        token &+= 1
        userScrolledAt = nil
    }

    mutating func noteUserScroll(at date: Date) {
        userScrolledAt = date
    }

    func allowsAutoFollow(at date: Date) -> Bool {
        guard let userScrolledAt else {
            return true
        }
        return date.timeIntervalSince(userScrolledAt) >= TranscriptLineEmphasis.manualScrollPause
    }
}

extension ScrollPhase {
    /// True only for scrolling the user drives (or its momentum and end). `animating`,
    /// which programmatic `scrollTo` produces, never counts.
    static func isUserScroll(from old: ScrollPhase, to new: ScrollPhase) -> Bool {
        let userPhases: [ScrollPhase] = [.tracking, .interacting, .decelerating]
        if userPhases.contains(new) {
            return true
        }
        return new == .idle && userPhases.contains(old)
    }
}

extension PracticeViewModel {
    /// The transcript cue under the playhead: the highlighted sentence.
    var currentCueIndex: Int? {
        let cues = timedCues
        guard !cues.isEmpty else {
            return nil
        }
        return SubtitleTimeline.cueIndex(at: playhead, in: cues)
    }

    /// An active jump: show the playhead (and `focus`, e.g. a clicked take) in the zoomed
    /// waveform, and tell the transcript to scroll to the current sentence right away.
    func revealPlayhead(focus: PracticeRegion? = nil) {
        jumpReveal.reveal()
        revealInTimeline(focus: focus)
    }

    func noteTranscriptUserScroll(at date: Date = Date()) {
        jumpReveal.noteUserScroll(at: date)
    }

    func transcriptAutoFollows(at date: Date = Date()) -> Bool {
        jumpReveal.allowsAutoFollow(at: date)
    }

    /// Pans (keeping the zoom) so `focus` and the playhead are visible; zooms out only when
    /// `focus` is longer than the visible window.
    private func revealInTimeline(focus: PracticeRegion?) {
        let visible = timelineViewport.duration
        guard visible > 0 else {
            return
        }
        if let focus, focus.start < timelineViewport.start || focus.end > timelineViewport.end {
            if focus.duration <= visible {
                timelineViewport = TimelineViewport(
                    start: focus.start - (visible - focus.duration) * 0.2,
                    duration: visible,
                    sourceDuration: project.duration
                )
            } else {
                timelineViewport = .fitting(focus, sourceDuration: project.duration)
            }
        }
        guard !timelineViewport.contains(playhead) else {
            return
        }
        timelineViewport = TimelineViewport(
            start: playhead - timelineViewport.duration * 0.2,
            duration: timelineViewport.duration,
            sourceDuration: project.duration
        )
    }
}
