import Foundation

extension PracticeViewModel {
    /// The transcript's highlighted sentence; changes only on a sentence change.
    var currentSentenceIndex: Int? {
        playheadSentence.cueIndex
    }

    /// Recomputes the current sentence; publishes only when it actually changed.
    func refreshPlayheadSentence() {
        let next = PlayheadSentence(cueIndex: currentCueIndex, sentence: currentSentence)
        if next != playheadSentence {
            playheadSentence = next
        }
    }
}
