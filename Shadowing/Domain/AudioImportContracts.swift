import Foundation

struct AudioAssetMetadata: Equatable, Sendable {
    let displayName: String
    let duration: TimeInterval
}

struct WaveformPresentation: Equatable, Sendable {
    let peaks: [Float]
    let warning: String?

    static let unavailable = WaveformPresentation(peaks: [], warning: nil)
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
