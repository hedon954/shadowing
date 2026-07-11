import Foundation

struct AppSettings: Codable, Equatable, Sendable {
    static let storeKey = "app.settings"
    static let supportedCountdownSeconds = [0, 1, 3, 5]
    static let supportedPlaybackRates: [Double] = [0.5, 0.75, 1, 1.25, 1.5]
    static let `default` = AppSettings()

    var countdownSeconds: Int = 3
    var playOriginalWhileRecording: Bool = true
    var defaultPlaybackRate: Double = 1
    var preferredInputDeviceUID: String?

    var normalizedCountdownSeconds: Int {
        Self.supportedCountdownSeconds.contains(countdownSeconds) ? countdownSeconds : 3
    }

    var normalizedPlaybackRate: Double {
        Self.supportedPlaybackRates.contains(defaultPlaybackRate) ? defaultPlaybackRate : 1
    }
}

extension ComparisonMode {
    /// Playhead is expressed on the original source timeline.
    var usesOriginalTimeline: Bool {
        switch self {
        case .original, .ab, .together:
            true
        case .selectedTake:
            false
        }
    }

    var emphasizesOriginal: Bool {
        switch self {
        case .original, .ab, .together:
            true
        case .selectedTake:
            false
        }
    }

    var emphasizesTake: Bool {
        switch self {
        case .selectedTake, .ab, .together:
            true
        case .original:
            false
        }
    }

    var displayName: String {
        switch self {
        case .original:
            "Original"
        case .selectedTake:
            "My Take"
        case .ab:
            "A/B"
        case .together:
            "Together"
        }
    }
}

protocol ComparisonPlaybackScheduler: Sendable {
    /// Short gap between original and take during A/B comparison playback.
    func waitForABGap() async throws
}

struct ContinuousComparisonPlaybackScheduler: ComparisonPlaybackScheduler {
    let gap: Duration

    init(gap: Duration = .milliseconds(400)) {
        self.gap = gap
    }

    func waitForABGap() async throws {
        try await Task.sleep(for: gap)
    }
}

struct ImmediateComparisonPlaybackScheduler: ComparisonPlaybackScheduler {
    func waitForABGap() async throws {
        await Task.yield()
    }
}

struct RecordingListItem: Equatable, Identifiable, Sendable {
    var id: UUID {
        project.id
    }

    let project: AudioProject
    let takeCount: Int
    let lastRecordedAt: Date
}

struct AudioInputDevice: Equatable, Identifiable, Sendable {
    let id: String
    let name: String
}

protocol AudioInputDeviceProviding: Sendable {
    func availableInputDevices() async -> [AudioInputDevice]
    func selectedInputDeviceID() async -> String?
    func selectInputDevice(id: String?) async throws
    func inputLevel() async -> Float
}
