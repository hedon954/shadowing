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
        guard start.isFinite, end.isFinite, sourceDuration.isFinite else {
            throw DomainError.invalidTimeRange
        }
        guard start >= 0, end <= sourceDuration, end > start else {
            throw DomainError.invalidTimeRange
        }
        guard Self.minimumDuration ... Self.maximumDuration ~= end - start else {
            throw DomainError.regionDurationOutOfBounds
        }

        self.id = id
        self.start = start
        self.end = end
    }
}

struct Take: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    let projectID: UUID
    let region: PracticeRegion
    let sequence: Int
    let relativeAudioPath: String
    let duration: TimeInterval
    let createdAt: Date
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
