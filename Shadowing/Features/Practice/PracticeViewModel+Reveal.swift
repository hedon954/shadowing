import Foundation
import SwiftUI

/// The one rule for when the zoomed waveform and the full transcript move to the playhead.
///
/// Every active jump (clicking a take or a sentence, dragging the playhead, opening a project)
/// bumps `token`; both views reveal the playhead on each bump, also when paused. Only the
/// user's own transcript scrolling pauses auto-follow during playback, for
/// `TranscriptLineEmphasis.manualScrollPause`. A reveal never starts that pause, and clears it.
/// The waveform part waits while the user drags on the waveform and runs once on release.
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
    /// `focus` is longer than the visible window. While the user drags on the zoomed waveform
    /// nothing moves: the reveal is remembered and applied once on release.
    private func revealInTimeline(focus: PracticeRegion?) {
        guard !deferTimelineMoveDuringGesture(focus: focus) else {
            return
        }
        let next = Self.revealedViewport(
            timelineViewport,
            focus: focus,
            playhead: playhead,
            sourceDuration: project.duration
        )
        if next != timelineViewport {
            timelineViewport = next
        }
    }

    /// The one rule for automatic waveform moves (reveals, playhead follow, take focus): while
    /// a drag on the waveform is active the visible range stays still and the move is kept in
    /// `deferredTimelineReveal`. Returns true when the move was deferred.
    func deferTimelineMoveDuringGesture(focus: PracticeRegion? = nil) -> Bool {
        guard suspendPlayheadFollow else {
            return false
        }
        deferredTimelineReveal = DeferredTimelineReveal(focus: focus ?? deferredTimelineReveal?.focus)
        return true
    }

    /// A drag on the waveform began (`true`) or ended (`false`). Ending applies a reveal that
    /// was held back during the drag, once; it pans only if its target is off-screen.
    func setTimelineGestureActive(_ active: Bool) {
        guard suspendPlayheadFollow != active else {
            return
        }
        suspendPlayheadFollow = active
        let deferred = deferredTimelineReveal
        deferredTimelineReveal = nil
        if !active, let deferred {
            revealInTimeline(focus: deferred.focus)
        }
    }

    static func revealedViewport(
        _ viewport: TimelineViewport,
        focus: PracticeRegion?,
        playhead: TimeInterval,
        sourceDuration: TimeInterval
    ) -> TimelineViewport {
        let visible = viewport.duration
        guard visible > 0 else {
            return viewport
        }
        var next = viewport
        if let focus, focus.start < next.start || focus.end > next.end {
            next = focus.duration <= visible
                ? TimelineViewport(
                    start: focus.start - (visible - focus.duration) * 0.2,
                    duration: visible,
                    sourceDuration: sourceDuration
                )
                : .fitting(focus, sourceDuration: sourceDuration)
        }
        guard !next.contains(playhead) else {
            return next
        }
        return TimelineViewport(
            start: playhead - next.duration * 0.2,
            duration: next.duration,
            sourceDuration: sourceDuration
        )
    }
}

/// A waveform reveal held back while the user drags on the zoomed waveform (see
/// `PracticeViewModel.deferTimelineMoveDuringGesture`).
struct DeferredTimelineReveal: Equatable, Sendable {
    var focus: PracticeRegion?
}
