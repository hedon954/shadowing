import Foundation

struct AudioProject: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    var sourceDisplayName: String
    var sourceBookmark: Data
    var duration: TimeInterval
    var playhead: TimeInterval
    var currentRegion: PracticeRegion?
    var selectedTakeID: UUID?
    var keptTakeID: UUID?
    var lastOpenedAt: Date
    var playbackRate: Double = 1
    /// Original filename of an attached plain-text script, if any.
    var scriptDisplayName: String?
}

struct PracticeRegion: Codable, Equatable, Identifiable, Sendable {
    static let minimumDuration: TimeInterval = 0.5
    static let maximumDuration: TimeInterval = 60

    let id: UUID
    let start: TimeInterval
    let end: TimeInterval

    var duration: TimeInterval {
        end - start
    }

    init(
        id: UUID = UUID(),
        start: TimeInterval,
        end: TimeInterval,
        sourceDuration: TimeInterval
    ) throws {
        try Self.validateRange(
            start: start,
            end: end,
            sourceDuration: sourceDuration,
            maximumDuration: Self.maximumDuration
        )
        self.id = id
        self.start = start
        self.end = end
    }

    /// Alignment span for a recorded Take on the source timeline.
    /// Unlike practice loop selection, this is not capped at 60 seconds.
    static func takeAlignment(
        id: UUID = UUID(),
        start: TimeInterval,
        end: TimeInterval,
        sourceDuration: TimeInterval
    ) throws -> PracticeRegion {
        try validateRange(
            start: start,
            end: end,
            sourceDuration: sourceDuration,
            maximumDuration: nil
        )
        return PracticeRegion(id: id, start: start, end: end)
    }

    static func fromDrag(
        anchor: TimeInterval,
        current: TimeInterval,
        sourceDuration: TimeInterval,
        id: UUID = UUID()
    ) throws -> PracticeRegion {
        try validateDragInput(anchor, current, sourceDuration: sourceDuration)

        let clampedAnchor = clamp(anchor, to: 0 ... sourceDuration)
        let clampedCurrent = clamp(current, to: 0 ... sourceDuration)
        let draggedForward = current >= anchor

        var start: TimeInterval
        var end: TimeInterval
        if draggedForward {
            start = clampedAnchor
            end = min(
                max(clampedCurrent, start + minimumDuration),
                min(start + maximumDuration, sourceDuration)
            )
            if end - start < minimumDuration {
                end = sourceDuration
                start = end - minimumDuration
            }
        } else {
            end = clampedAnchor
            start = max(
                min(clampedCurrent, end - minimumDuration),
                max(end - maximumDuration, 0)
            )
            if end - start < minimumDuration {
                start = 0
                end = minimumDuration
            }
        }

        return try PracticeRegion(
            id: id,
            start: start,
            end: end,
            sourceDuration: sourceDuration
        )
    }

    func adjustingStart(
        to proposedStart: TimeInterval,
        sourceDuration: TimeInterval
    ) throws -> PracticeRegion {
        guard proposedStart.isFinite else {
            throw DomainError.invalidTimeRange
        }
        let region = try clamped(to: sourceDuration)
        let lowerBound = max(0, region.end - Self.maximumDuration)
        let upperBound = region.end - Self.minimumDuration
        return try PracticeRegion(
            id: id,
            start: Self.clamp(proposedStart, to: lowerBound ... upperBound),
            end: region.end,
            sourceDuration: sourceDuration
        )
    }

    func adjustingEnd(
        to proposedEnd: TimeInterval,
        sourceDuration: TimeInterval
    ) throws -> PracticeRegion {
        guard proposedEnd.isFinite else {
            throw DomainError.invalidTimeRange
        }
        let region = try clamped(to: sourceDuration)
        let lowerBound = region.start + Self.minimumDuration
        let upperBound = min(sourceDuration, region.start + Self.maximumDuration)
        return try PracticeRegion(
            id: id,
            start: region.start,
            end: Self.clamp(proposedEnd, to: lowerBound ... upperBound),
            sourceDuration: sourceDuration
        )
    }

    func clamped(to sourceDuration: TimeInterval) throws -> PracticeRegion {
        try Self.validateSourceDuration(sourceDuration)
        let clampedDuration = min(duration, sourceDuration, Self.maximumDuration)
        let clampedStart = Self.clamp(start, to: 0 ... sourceDuration - clampedDuration)
        return try PracticeRegion(
            id: id,
            start: clampedStart,
            end: clampedStart + clampedDuration,
            sourceDuration: sourceDuration
        )
    }

    init(
        id: UUID,
        persistedStart start: TimeInterval,
        end: TimeInterval
    ) throws {
        guard start.isFinite, end.isFinite, start >= 0, end > start else {
            throw DomainError.invalidTimeRange
        }
        guard Self.minimumDuration ... Self.maximumDuration ~= end - start else {
            throw DomainError.regionDurationOutOfBounds
        }

        self.id = id
        self.start = start
        self.end = end
    }

    /// Restores a Take alignment span from persistence without the 60s loop limit.
    init(
        id: UUID,
        persistedTakeStart start: TimeInterval,
        end: TimeInterval
    ) throws {
        guard start.isFinite, end.isFinite, start >= 0, end > start else {
            throw DomainError.invalidTimeRange
        }
        guard end - start >= Self.minimumDuration else {
            throw DomainError.regionDurationOutOfBounds
        }

        self.id = id
        self.start = start
        self.end = end
    }

    private init(id: UUID, start: TimeInterval, end: TimeInterval) {
        self.id = id
        self.start = start
        self.end = end
    }

    private static func validateRange(
        start: TimeInterval,
        end: TimeInterval,
        sourceDuration: TimeInterval,
        maximumDuration: TimeInterval?
    ) throws {
        guard start.isFinite, end.isFinite, sourceDuration.isFinite else {
            throw DomainError.invalidTimeRange
        }
        guard start >= 0, end <= sourceDuration, end > start else {
            throw DomainError.invalidTimeRange
        }
        let duration = end - start
        guard duration >= Self.minimumDuration else {
            throw DomainError.regionDurationOutOfBounds
        }
        if let maximumDuration, duration > maximumDuration {
            throw DomainError.regionDurationOutOfBounds
        }
    }

    private static func validateDragInput(
        _ anchor: TimeInterval,
        _ current: TimeInterval,
        sourceDuration: TimeInterval
    ) throws {
        guard anchor.isFinite, current.isFinite else {
            throw DomainError.invalidTimeRange
        }
        try validateSourceDuration(sourceDuration)
    }

    private static func validateSourceDuration(_ sourceDuration: TimeInterval) throws {
        guard sourceDuration.isFinite, sourceDuration >= minimumDuration else {
            throw DomainError.invalidTimeRange
        }
    }

    private static func clamp<T: Comparable>(_ value: T, to range: ClosedRange<T>) -> T {
        min(max(value, range.lowerBound), range.upperBound)
    }
}

struct Take: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    let projectID: UUID
    let region: PracticeRegion
    /// Stable label number ("Take N"); does not change when the track is reordered.
    let sequence: Int
    /// Vertical order under Original; lower values appear closer to Original.
    let displayOrder: Int
    let relativeAudioPath: String
    let duration: TimeInterval
    let createdAt: Date

    init(
        id: UUID = UUID(),
        projectID: UUID,
        region: PracticeRegion,
        sequence: Int,
        displayOrder: Int? = nil,
        relativeAudioPath: String,
        duration: TimeInterval,
        createdAt: Date
    ) throws {
        guard sequence > 0,
              !relativeAudioPath.isEmpty,
              duration.isFinite,
              duration >= PracticeRegion.minimumDuration
        else {
            throw DomainError.invalidTake
        }

        self.id = id
        self.projectID = projectID
        self.region = region
        self.sequence = sequence
        self.displayOrder = displayOrder ?? sequence
        self.relativeAudioPath = relativeAudioPath
        self.duration = duration
        self.createdAt = createdAt
    }

    func withDisplayOrder(_ displayOrder: Int) throws -> Take {
        try Take(
            id: id,
            projectID: projectID,
            region: region,
            sequence: sequence,
            displayOrder: displayOrder,
            relativeAudioPath: relativeAudioPath,
            duration: duration,
            createdAt: createdAt
        )
    }
}

enum DomainError: Error, Equatable, LocalizedError, Sendable {
    case invalidTimeRange
    case regionDurationOutOfBounds
    case invalidTake

    var errorDescription: String? {
        switch self {
        case .invalidTimeRange:
            "The selected time range is invalid."
        case .regionDurationOutOfBounds:
            "A practice region must be between 0.5 and 60 seconds."
        case .invalidTake:
            "The recording is not a valid take."
        }
    }
}
