import Foundation

struct AudioAssetMetadata: Equatable, Sendable {
    let displayName: String
    let duration: TimeInterval
}

struct WaveformEnvelopePoint: Codable, Equatable, Sendable {
    let minimum: Float
    let maximum: Float

    init(minimum: Float, maximum: Float) {
        self.minimum = min(max(minimum, -1), 1)
        self.maximum = min(max(maximum, -1), 1)
    }

    init(amplitude: Float) {
        let normalized = min(max(abs(amplitude), 0), 1)
        self.init(minimum: -normalized, maximum: normalized)
    }

    var amplitude: Float {
        max(abs(minimum), abs(maximum))
    }
}

struct WaveformEnvelopeLevel: Codable, Equatable, Sendable {
    let framesPerPoint: Int
    let points: [WaveformEnvelopePoint]

    init(framesPerPoint: Int, points: [WaveformEnvelopePoint]) {
        self.framesPerPoint = framesPerPoint
        self.points = points
    }

    init(framesPerPeak: Int, peaks: [Float]) {
        self.init(
            framesPerPoint: framesPerPeak,
            points: peaks.map(WaveformEnvelopePoint.init(amplitude:))
        )
    }

    var framesPerPeak: Int {
        framesPerPoint
    }

    var peaks: [Float] {
        points.map(\.amplitude)
    }
}

struct WaveformPresentation: Equatable, Sendable {
    let duration: TimeInterval
    let sampleRate: Double
    let levels: [WaveformEnvelopeLevel]
    let warning: String?

    init(
        duration: TimeInterval,
        sampleRate: Double,
        levels: [WaveformEnvelopeLevel],
        warning: String?
    ) {
        self.duration = duration
        self.sampleRate = sampleRate
        self.levels = levels.sorted { $0.framesPerPoint < $1.framesPerPoint }
        self.warning = warning
    }

    init(peaks: [Float], warning: String?) {
        self.init(
            duration: 0,
            sampleRate: 1,
            levels: [
                WaveformEnvelopeLevel(
                    framesPerPeak: 1,
                    peaks: peaks
                )
            ],
            warning: warning
        )
    }

    var peaks: [Float] {
        levels.last?.peaks ?? []
    }

    static let unavailable = WaveformPresentation(
        duration: 0,
        sampleRate: 1,
        levels: [],
        warning: nil
    )
}

struct PreparedPractice: Equatable, Sendable {
    let project: AudioProject
    let waveform: WaveformPresentation
}

enum AudioSourceError: Error, Equatable, LocalizedError, Sendable {
    case unsupportedFormat
    case fileMissing
    case permissionDenied
    case corruptFile
    case noAudioTrack
    case invalidDuration
    case bookmarkStale
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .unsupportedFormat:
            "Only MP3 audio files are supported."
        case .fileMissing:
            "The audio file could not be found."
        case .permissionDenied:
            "Shadowing no longer has permission to read this audio file."
        case .corruptFile:
            "The audio file is damaged or cannot be decoded."
        case .noAudioTrack:
            "The selected file does not contain an audio track."
        case .invalidDuration:
            "The audio file does not have a valid duration."
        case .bookmarkStale:
            "Access to this audio file must be restored."
        case let .failed(message):
            message
        }
    }

    var recoverySuggestion: String {
        switch self {
        case .unsupportedFormat, .corruptFile, .noAudioTrack, .invalidDuration:
            "Choose another MP3 file."
        case .fileMissing, .permissionDenied, .bookmarkStale:
            "Locate the file again to restore access."
        case .failed:
            "Try again or choose another MP3 file."
        }
    }
}

protocol AudioFileChoosing: Sendable {
    @MainActor
    func chooseMP3() async -> URL?
}

protocol AudioFileValidating: Sendable {
    func validate(_ url: URL) throws
}

protocol AudioAssetMetadataLoading: Sendable {
    func loadMetadata(from url: URL) async throws -> AudioAssetMetadata
}

protocol WaveformPreparing: Sendable {
    func prepareWaveform(from url: URL) async throws -> WaveformPresentation
}

protocol PracticeSessionPreparing: Sendable {
    func prepareNewSource(at url: URL) async throws -> PreparedPractice
    func prepareExistingProject(id: UUID) async throws -> PreparedPractice
    func relocateProject(id: UUID, to url: URL) async throws -> PreparedPractice
    func endSession() async
}
