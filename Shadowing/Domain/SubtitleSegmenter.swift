import Foundation

/// Groups recognized words into subtitle cues: one sentence per cue where possible, split
/// at long pauses and kept short enough to read while listening.
enum SubtitleSegmenter {
    /// A silence this long always starts a new cue.
    static let pauseBreak: TimeInterval = 0.9
    /// Longer cues break at the next comma.
    static let softWordLimit = 8
    static let maximumWords = 16
    static let maximumDuration: TimeInterval = 7

    static func cues(from words: [TranscribedWord]) -> [SubtitleCue] {
        let words = words
            .filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .sorted { $0.start < $1.start }
        var cues: [SubtitleCue] = []
        var current: [TranscribedWord] = []
        for (index, word) in words.enumerated() {
            current.append(word)
            let next = index + 1 < words.count ? words[index + 1] : nil
            if shouldBreak(after: current, next: next) {
                cues.append(cue(from: current))
                current = []
            }
        }
        return cues
    }

    /// Words as running text, for showing recognition while it happens.
    static func text(of words: [TranscribedWord]) -> String {
        words.map(\.text).joined(separator: " ")
    }

    private static func shouldBreak(after current: [TranscribedWord], next: TranscribedWord?) -> Bool {
        guard let last = current.last, let first = current.first, let next else {
            return true
        }
        let ending = last.text.last
        let endsSentence = ending.map { ".!?…".contains($0) } ?? false
        let endsClause = ending.map { ",;:".contains($0) } ?? false
        let pause = next.start - last.end
        let length = next.end - first.start
        return endsSentence
            || pause >= pauseBreak
            || current.count >= maximumWords
            || (endsClause && current.count >= softWordLimit)
            || length > maximumDuration
    }

    private static func cue(from words: [TranscribedWord]) -> SubtitleCue {
        let start = words.first?.start ?? 0
        let end = max(words.map(\.end).max() ?? start, start)
        return SubtitleCue(start: start, end: end, text: text(of: words))
    }
}
