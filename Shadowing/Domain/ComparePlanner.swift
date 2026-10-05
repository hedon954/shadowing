import Foundation

/// The three ways "Compare" plays the chosen sentence.
enum CompareMode: String, CaseIterable, Identifiable, Sendable {
    case original
    case mine
    case originalThenMine

    var id: String {
        rawValue
    }
}

enum CompareStep: Equatable, Sendable {
    /// Part of the original, on the source timeline.
    case original(PracticeRegion)
    /// Part of a take, in take-file time (offset already applied).
    case take(id: UUID, region: PracticeRegion)
}

enum ComparePlanner {
    /// Shortest take part worth playing; less means the take does not cover the sentence.
    static let minimumTakePart: TimeInterval = PracticeRegion.minimumDuration

    static func steps(
        sentence: SentenceChunk,
        sourceDuration: TimeInterval,
        take: Take?,
        offset: TimeInterval,
        mode: CompareMode
    ) -> [CompareStep] {
        let original = sentence.region(sourceDuration: sourceDuration).map(CompareStep.original)
        let mine = take.flatMap { takePart(sentence: sentence, take: $0, offset: offset) }
        switch mode {
        case .original:
            return original.map { [$0] } ?? []
        case .mine:
            return mine.map { [$0] } ?? []
        case .originalThenMine:
            return [original, mine].compactMap(\.self)
        }
    }

    /// The take-file span that lines up with `sentence`, clipped to what was recorded.
    static func takePart(sentence: SentenceChunk, take: Take, offset: TimeInterval) -> CompareStep? {
        let offset = RecordingAlignment.clamped(offset)
        let start = RecordingAlignment.takeTime(
            forSourceTime: sentence.start,
            regionStart: take.region.start,
            offset: offset
        )
        let end = RecordingAlignment.takeTime(
            forSourceTime: sentence.end,
            regionStart: take.region.start,
            offset: offset
        )
        let clippedStart = max(start, 0)
        let clippedEnd = min(end, take.duration)
        guard clippedEnd - clippedStart >= minimumTakePart,
              let region = try? PracticeRegion.takeAlignment(
                  start: clippedStart,
                  end: clippedEnd,
                  sourceDuration: take.duration
              )
        else {
            return nil
        }
        return .take(id: take.id, region: region)
    }
}
