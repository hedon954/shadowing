import Foundation

/// How far the voice in a take sits from the original, in seconds.
///
/// The microphone starts before the original starts playing, and both sides add hardware latency,
/// so the moment the user hears the start of the recorded region is `offset` seconds into the
/// take file. Positive means the take has extra lead-in. Old takes have no measurement and use 0.
enum RecordingAlignment {
    static let limit: TimeInterval = 1

    static func clamped(_ offset: TimeInterval) -> TimeInterval {
        guard offset.isFinite else {
            return 0
        }
        return min(max(offset, -limit), limit)
    }

    /// `playerStart - micFirstBuffer + outputLatency + inputLatency`, clamped to ±1 s.
    static func measuredOffset(
        micFirstBufferSeconds: TimeInterval,
        playerStartSeconds: TimeInterval,
        outputLatency: TimeInterval,
        inputLatency: TimeInterval
    ) -> TimeInterval {
        clamped(playerStartSeconds - micFirstBufferSeconds + outputLatency + inputLatency)
    }

    /// Take-file time for a time on the original timeline.
    static func takeTime(
        forSourceTime time: TimeInterval,
        regionStart: TimeInterval,
        offset: TimeInterval
    ) -> TimeInterval {
        time - regionStart + offset
    }

    /// Original-timeline time for a time in the take file.
    static func sourceTime(
        forTakeTime time: TimeInterval,
        regionStart: TimeInterval,
        offset: TimeInterval
    ) -> TimeInterval {
        regionStart + time - offset
    }
}

protocol RecordingAlignmentStoring: Sendable {
    /// The saved offset, or 0 when the file is missing or unreadable. Never throws.
    func offset(for takeID: UUID) -> TimeInterval
    func saveOffset(_ offset: TimeInterval, for takeID: UUID) throws
    func deleteOffset(for takeID: UUID)
    /// The sidecar file, so deleting a take can move it to the Trash with the audio.
    func fileURL(for takeID: UUID) -> URL?
}

/// `Recordings/<take id>.json` next to the takes, in the app's own Application Support folder.
/// No database change: a missing file simply means "not measured".
struct LocalRecordingAlignmentStore: RecordingAlignmentStoring {
    struct Sidecar: Codable, Equatable {
        var version = 1
        var offsetSeconds: Double
    }

    let rootDirectory: URL

    func url(for takeID: UUID) -> URL {
        rootDirectory.appendingPathComponent("\(takeID.uuidString).json", isDirectory: false)
    }

    func offset(for takeID: UUID) -> TimeInterval {
        guard let data = try? Data(contentsOf: url(for: takeID)),
              let sidecar = try? JSONDecoder().decode(Sidecar.self, from: data)
        else {
            return 0
        }
        return RecordingAlignment.clamped(sidecar.offsetSeconds)
    }

    func saveOffset(_ offset: TimeInterval, for takeID: UUID) throws {
        try FileManager.default.createDirectory(at: rootDirectory, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(Sidecar(offsetSeconds: RecordingAlignment.clamped(offset)))
        try data.write(to: url(for: takeID), options: .atomic)
    }

    func deleteOffset(for takeID: UUID) {
        try? FileManager.default.removeItem(at: url(for: takeID))
    }

    func fileURL(for takeID: UUID) -> URL? {
        url(for: takeID)
    }
}
