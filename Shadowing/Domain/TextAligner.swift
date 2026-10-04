import Foundation

struct TextAlignment: Equatable, Sendable {
    let cues: [SubtitleCue]
    /// Share of the text's words found in the recognized speech (0...1).
    let matchRatio: Double

    var isAligned: Bool {
        matchRatio >= TextAligner.minimumMatchRatio
    }
}

/// Times a plain-text script by matching its words, in order, to recognized words.
/// Pure and deterministic so the threshold and edge cases are unit tested.
enum TextAligner {
    /// Below this share of matched words the text is shown untimed ("Can't align").
    static let minimumMatchRatio = 0.6
    /// How far ahead in the recognized words a text word may be found.
    static let searchWindow = 60

    private struct Token {
        let sentence: Int
        let key: String
    }

    private struct SpokenToken {
        let key: String
        let start: TimeInterval
        let end: TimeInterval
    }

    static func align(script: String, words: [TranscribedWord]) -> TextAlignment {
        let sentences = ScriptSentences.split(script)
        let tokens = sentences.enumerated().flatMap { index, sentence in
            normalizedTokens(sentence).map { Token(sentence: index, key: $0) }
        }
        let spoken = words.flatMap { word in
            normalizedTokens(word.text).map { SpokenToken(key: $0, start: word.start, end: word.end) }
        }
        let matches = match(tokens.map(\.key), spoken.map(\.key))
        let matchedCount = matches.compactMap(\.self).count
        guard !tokens.isEmpty, matchedCount > 0 else {
            return TextAlignment(cues: [], matchRatio: 0)
        }
        let times = tokenTimes(matches: matches, spoken: spoken)

        var cues: [SubtitleCue] = []
        for (index, sentence) in sentences.enumerated() {
            let members = tokens.indices.filter { tokens[$0].sentence == index }
            guard let first = members.first, let last = members.last else {
                continue
            }
            let start = max(times[first].start, cues.last?.start ?? 0)
            let end = max(times[last].end, start)
            cues.append(SubtitleCue(start: start, end: end, text: sentence))
        }
        return TextAlignment(
            cues: cues,
            matchRatio: Double(matchedCount) / Double(tokens.count)
        )
    }

    /// Greedy in-order matching. A match further than two words ahead must be confirmed by
    /// the next word as well, so common words such as "the" don't pull the cursor away.
    private static func match(_ text: [String], _ spoken: [String]) -> [Int?] {
        var matches = [Int?](repeating: nil, count: text.count)
        var cursor = 0
        for index in text.indices {
            guard cursor < spoken.count else {
                break
            }
            let limit = min(cursor + searchWindow, spoken.count)
            for candidate in cursor ..< limit where spoken[candidate] == text[index] {
                let isNear = candidate - cursor <= 2
                let nextAgrees = index + 1 < text.count
                    && candidate + 1 < spoken.count
                    && spoken[candidate + 1] == text[index + 1]
                if isNear || nextAgrees {
                    matches[index] = candidate
                    cursor = candidate + 1
                    break
                }
            }
        }
        return matches
    }

    /// Matched words take the recognized times; the others are spread evenly between their
    /// matched neighbours.
    private static func tokenTimes(
        matches: [Int?],
        spoken: [SpokenToken]
    ) -> [(start: TimeInterval, end: TimeInterval)] {
        let matched = matches.indices.filter { matches[$0] != nil }
        var times = [(start: TimeInterval, end: TimeInterval)](repeating: (0, 0), count: matches.count)
        var previous: Int?
        var nextPosition = 0
        for index in matches.indices {
            if let spokenIndex = matches[index] {
                times[index] = (spoken[spokenIndex].start, spoken[spokenIndex].end)
                previous = index
                nextPosition += 1
                continue
            }
            let next = nextPosition < matched.count ? matched[nextPosition] : nil
            let low = previous.map { times[$0].end } ?? next.map { spoken[matches[$0] ?? 0].start } ?? 0
            let high = next.map { spoken[matches[$0] ?? 0].start } ?? low
            let lower = previous ?? -1
            let upper = next ?? matches.count
            let fraction = Double(index - lower) / Double(upper - lower)
            let time = low + (high - low) * fraction
            times[index] = (time, time)
        }
        return times
    }

    /// Lowercased words without punctuation; apostrophes vanish ("I'm" → "im") and hyphens split.
    static func normalizedTokens(_ text: String) -> [String] {
        text.lowercased()
            .split(whereSeparator: { $0.isWhitespace || "-–—/".contains($0) })
            .map { String($0.filter { $0.isLetter || $0.isNumber }) }
            .filter { !$0.isEmpty }
    }
}

/// Splits a script into sentences. Single line breaks are wrapping, blank lines end a paragraph.
enum ScriptSentences {
    static let maximumWords = 32
    private static let terminators: Set<Character> = [".", "!", "?", "…"]
    private static let closers: Set<Character> = [".", "!", "?", "…", "\"", "'", "”", "’", ")", "]"]
    private static let abbreviations: Set<String> = [
        "mr.", "mrs.", "ms.", "dr.", "prof.", "st.", "jr.", "sr.", "vs.", "e.g.", "i.e.", "u.s."
    ]

    static func split(_ text: String) -> [String] {
        let paragraphs = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .components(separatedBy: "\n")
            .split(whereSeparator: { $0.trimmingCharacters(in: .whitespaces).isEmpty })
            .map { $0.joined(separator: " ") }
        return paragraphs.flatMap(sentences(in:)).flatMap(limitLength)
    }

    private static func sentences(in paragraph: String) -> [String] {
        let characters = Array(paragraph)
        var sentences: [String] = []
        var current = ""
        var index = 0
        while index < characters.count {
            let character = characters[index]
            current.append(character)
            index += 1
            guard terminators.contains(character) else {
                continue
            }
            while index < characters.count, closers.contains(characters[index]) {
                current.append(characters[index])
                index += 1
            }
            let atBoundary = index >= characters.count || characters[index].isWhitespace
            let lastWord = current.split(whereSeparator: \.isWhitespace).last.map { $0.lowercased() } ?? ""
            if atBoundary, !abbreviations.contains(lastWord) {
                appendTrimmed(current, to: &sentences)
                current = ""
            }
        }
        appendTrimmed(current, to: &sentences)
        return sentences
    }

    private static func appendTrimmed(_ text: String, to sentences: inout [String]) {
        let collapsed = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        if !collapsed.isEmpty {
            sentences.append(collapsed)
        }
    }

    /// Very long sentences are hard to follow; break them after a comma, or at the limit.
    private static func limitLength(_ sentence: String) -> [String] {
        var words = sentence.split(separator: " ").map(String.init)
        var parts: [String] = []
        while words.count > maximumWords {
            let window = words.prefix(maximumWords)
            let comma = window.indices.dropFirst(maximumWords / 3).last { index in
                window[index].hasSuffix(",") || window[index].hasSuffix(";")
            }
            let cut = (comma ?? maximumWords - 1) + 1
            parts.append(words.prefix(cut).joined(separator: " "))
            words.removeFirst(cut)
        }
        if !words.isEmpty {
            parts.append(words.joined(separator: " "))
        }
        return parts
    }
}
