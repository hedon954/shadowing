import Foundation

/// One spoken stretch of the original, on the source timeline.
struct SentenceChunk: Codable, Equatable, Hashable, Sendable {
    let start: TimeInterval
    let end: TimeInterval

    var duration: TimeInterval {
        end - start
    }

    func contains(_ time: TimeInterval) -> Bool {
        time >= start && time < end
    }

    /// The same span as a practice region: at least the shortest region allowed, at most the longest.
    func region(sourceDuration: TimeInterval) -> PracticeRegion? {
        let minimum = PracticeRegion.minimumDuration
        let end = min(max(end, start + minimum), start + PracticeRegion.maximumDuration, sourceDuration)
        let start = max(min(start, end - minimum), 0)
        return try? PracticeRegion(start: start, end: end, sourceDuration: sourceDuration)
    }
}

/// Without subtitles, sentences are the sounds between pauses.
enum PauseSegmenter {
    struct Parameters: Equatable, Sendable {
        /// Quiet runs at least this long end a sentence.
        var minimumPause: TimeInterval = 0.3
        /// Shorter sounds join the previous sentence (breaths, clicks).
        var minimumChunk: TimeInterval = 0.5
        /// Kept around the sound so playback does not clip the first and last syllable.
        var padding: TimeInterval = 0.08
        /// Quiet means below this share of the way from the noise floor to the loud level.
        var thresholdFraction: Float = 0.12
    }

    /// Uses the finest level of the waveform envelope, so no audio has to be decoded again.
    static func chunks(
        in waveform: WaveformPresentation,
        parameters: Parameters = Parameters()
    ) -> [SentenceChunk] {
        guard let level = waveform.levels.first, waveform.sampleRate > 0, waveform.duration > 0 else {
            return []
        }
        let secondsPerPoint = Double(level.framesPerPoint) / waveform.sampleRate
        return chunks(
            amplitudes: level.points.map(\.amplitude),
            secondsPerPoint: secondsPerPoint,
            duration: waveform.duration,
            parameters: parameters
        )
    }

    static func chunks(
        amplitudes: [Float],
        secondsPerPoint: TimeInterval,
        duration: TimeInterval,
        parameters: Parameters = Parameters()
    ) -> [SentenceChunk] {
        guard !amplitudes.isEmpty, secondsPerPoint > 0 else {
            return []
        }
        let threshold = quietThreshold(amplitudes, fraction: parameters.thresholdFraction)
        let minimumPausePoints = max(Int((parameters.minimumPause / secondsPerPoint).rounded(.up)), 1)
        var spans: [(start: Int, end: Int)] = []
        var soundStart: Int?
        var quietRun = 0
        for (index, amplitude) in amplitudes.enumerated() {
            if amplitude > threshold {
                if soundStart == nil {
                    soundStart = index
                }
                quietRun = 0
            } else if let start = soundStart {
                quietRun += 1
                if quietRun >= minimumPausePoints {
                    spans.append((start, index - quietRun + 1))
                    soundStart = nil
                    quietRun = 0
                }
            }
        }
        if let start = soundStart {
            spans.append((start, amplitudes.count - quietRun))
        }
        let raw = spans.map { span in
            SentenceChunk(
                start: max(Double(span.start) * secondsPerPoint - parameters.padding, 0),
                end: min(Double(span.end) * secondsPerPoint + parameters.padding, duration)
            )
        }
        return merged(raw, minimumChunk: parameters.minimumChunk)
    }

    private static func quietThreshold(_ amplitudes: [Float], fraction: Float) -> Float {
        let sorted = amplitudes.sorted()
        let floor = sorted[Int(Double(sorted.count - 1) * 0.1)]
        let loud = sorted[Int(Double(sorted.count - 1) * 0.95)]
        return max(floor + (loud - floor) * fraction, 0.004)
    }

    private static func merged(_ chunks: [SentenceChunk], minimumChunk: TimeInterval) -> [SentenceChunk] {
        var result: [SentenceChunk] = []
        for chunk in chunks {
            if let last = result.last, chunk.duration < minimumChunk || last.duration < minimumChunk {
                result[result.count - 1] = SentenceChunk(start: last.start, end: chunk.end)
            } else {
                result.append(chunk)
            }
        }
        return result
    }

    /// The sentence to play at `time`: the one under it, else the next one, else the last.
    static func chunk(at time: TimeInterval, in chunks: [SentenceChunk]) -> SentenceChunk? {
        if let match = chunks.first(where: { $0.contains(time) }) {
            return match
        }
        return chunks.first { $0.start > time } ?? chunks.last
    }
}
