import Foundation

enum SubtitleParseError: Error, Equatable, LocalizedError, Sendable {
    case noCues

    var errorDescription: String? {
        String(localized: "This file has no timed subtitles.")
    }
}

/// Reads .srt, .vtt and .lrc text into cues sorted by start time.
enum SubtitleParser {
    static let lastLyricDuration: TimeInterval = 5

    static func parse(_ text: String, format: SubtitleFileFormat) throws -> [SubtitleCue] {
        var normalized = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        if normalized.hasPrefix("\u{FEFF}") {
            normalized.removeFirst()
        }
        let cues = switch format {
        case .srt, .vtt:
            parseBlocks(normalized)
        case .lrc:
            parseLyrics(normalized)
        }
        let sorted = cues
            .filter { !$0.text.isEmpty }
            .sorted { $0.start < $1.start }
        guard !sorted.isEmpty else {
            throw SubtitleParseError.noCues
        }
        return sorted
    }

    /// SRT and WebVTT share the "start --> end" line followed by text lines up to a blank line.
    /// Index lines, the WEBVTT header, NOTE and STYLE blocks have no arrow and are skipped.
    private static func parseBlocks(_ text: String) -> [SubtitleCue] {
        let lines = text.components(separatedBy: "\n")
        var cues: [SubtitleCue] = []
        var index = 0
        while index < lines.count {
            guard let timing = timing(in: lines[index]) else {
                index += 1
                continue
            }
            index += 1
            var body: [String] = []
            while index < lines.count, !lines[index].trimmingCharacters(in: .whitespaces).isEmpty {
                body.append(lines[index])
                index += 1
            }
            cues.append(
                SubtitleCue(
                    start: timing.start,
                    end: max(timing.end, timing.start),
                    text: cleanText(body.joined(separator: " "))
                )
            )
        }
        return cues
    }

    private static func timing(in line: String) -> (start: TimeInterval, end: TimeInterval)? {
        let parts = line.components(separatedBy: "-->")
        guard parts.count == 2,
              let start = timestamp(Substring(parts[0])),
              let endToken = parts[1].split(whereSeparator: \.isWhitespace).first,
              let end = timestamp(endToken)
        else {
            return nil
        }
        return (start, end)
    }

    /// Accepts `HH:MM:SS,mmm`, `HH:MM:SS.mmm`, `MM:SS.mmm` and `MM:SS`.
    static func timestamp(_ token: Substring) -> TimeInterval? {
        let trimmed = token.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")
        let parts = trimmed.split(separator: ":", omittingEmptySubsequences: false)
        guard (2 ... 3).contains(parts.count) else {
            return nil
        }
        var seconds: TimeInterval = 0
        for part in parts {
            guard !part.isEmpty,
                  part.allSatisfy({ $0.isASCII && ($0.isNumber || $0 == ".") }),
                  let value = Double(part)
            else {
                return nil
            }
            seconds = seconds * 60 + value
        }
        return seconds
    }

    /// LRC: `[mm:ss.xx]line`, several stamps per line allowed, `[offset:±ms]` shifts all times.
    /// A line ends where the next one starts.
    private static func parseLyrics(_ text: String) -> [SubtitleCue] {
        var offset: TimeInterval = 0
        var stamped: [(time: TimeInterval, text: String)] = []
        for rawLine in text.components(separatedBy: "\n") {
            var line = Substring(rawLine.trimmingCharacters(in: .whitespaces))
            var times: [TimeInterval] = []
            while line.hasPrefix("["), let close = line.firstIndex(of: "]") {
                let tag = line[line.index(after: line.startIndex) ..< close]
                if let time = timestamp(tag) {
                    times.append(time)
                } else if let milliseconds = offsetMilliseconds(tag) {
                    offset = milliseconds / 1000
                }
                line = line[line.index(after: close)...]
            }
            let body = cleanText(String(line))
            stamped.append(contentsOf: times.map { (time: $0, text: body) })
        }
        stamped.sort { $0.time < $1.time }

        var cues: [SubtitleCue] = []
        for (index, entry) in stamped.enumerated() where !entry.text.isEmpty {
            let start = max(entry.time - offset, 0)
            let next = index + 1 < stamped.count
                ? max(stamped[index + 1].time - offset, 0)
                : start + lastLyricDuration
            cues.append(SubtitleCue(start: start, end: max(next, start), text: entry.text))
        }
        return cues
    }

    private static func offsetMilliseconds(_ tag: Substring) -> Double? {
        guard tag.lowercased().hasPrefix("offset:") else {
            return nil
        }
        return Double(tag.dropFirst(7).trimmingCharacters(in: .whitespaces))
    }

    /// Drops markup (`<i>`, `<v Speaker>`, `{\an8}`, LRC word stamps) and collapses whitespace.
    static func cleanText(_ text: String) -> String {
        let withoutTags = text
            .replacingOccurrences(of: "<[^>]*>", with: "", options: .regularExpression)
            .replacingOccurrences(of: "\\{[^}]*\\}", with: "", options: .regularExpression)
        let decoded = withoutTags
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&amp;", with: "&")
        return decoded
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }
}

enum SubtitleSRTWriter {
    static func srt(from cues: [SubtitleCue]) -> String {
        cues.enumerated()
            .map { index, cue in
                "\(index + 1)\n\(timestamp(cue.start)) --> \(timestamp(cue.end))\n\(cue.text)\n"
            }
            .joined(separator: "\n")
    }

    static func timestamp(_ time: TimeInterval) -> String {
        let milliseconds = Int((max(time, 0) * 1000).rounded())
        let hours = milliseconds / 3_600_000
        let minutes = milliseconds / 60000 % 60
        let seconds = milliseconds / 1000 % 60
        let fraction = milliseconds % 1000
        return String(format: "%02d:%02d:%02d,%03d", hours, minutes, seconds, fraction)
    }
}

enum SubtitleTimeline {
    /// The cue being spoken: the last one that has started. A pause keeps the previous cue.
    static func cueIndex(at time: TimeInterval, in cues: [SubtitleCue]) -> Int? {
        var low = 0
        var high = cues.count
        while low < high {
            let middle = (low + high) / 2
            if cues[middle].start <= time {
                low = middle + 1
            } else {
                high = middle
            }
        }
        return low == 0 ? nil : low - 1
    }

    /// The row an active jump scrolls the transcript to: the sentence under the playhead (or the
    /// nearest earlier one), else the first sentence when the playhead is before it. Never past
    /// the last row, never "nothing" while there are cues.
    static func revealIndex(current: Int?, cueCount: Int) -> Int? {
        guard cueCount > 0 else {
            return nil
        }
        return min(max(current ?? 0, 0), cueCount - 1)
    }

    static let paragraphPause: TimeInterval = 1.5
    static let preferredParagraphLength = 4
    static let maximumParagraphLength = 6

    /// Groups cues into short paragraphs: after a long pause, or after a few full sentences.
    static func paragraphs(_ cues: [SubtitleCue]) -> [Range<Int>] {
        guard !cues.isEmpty else {
            return []
        }
        var ranges: [Range<Int>] = []
        var start = 0
        for index in 1 ..< cues.count {
            let length = index - start
            let pause = cues[index].start - cues[index - 1].end
            let endsSentence = cues[index - 1].text.last.map { ".!?…\"”".contains($0) } ?? false
            let isBreak = pause >= paragraphPause
                || (length >= preferredParagraphLength && endsSentence)
                || length >= maximumParagraphLength
            if isBreak {
                ranges.append(start ..< index)
                start = index
            }
        }
        ranges.append(start ..< cues.count)
        return ranges
    }
}
