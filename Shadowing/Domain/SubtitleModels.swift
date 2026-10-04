import CryptoKit
import Foundation

/// One timed line of subtitles on the source timeline.
struct SubtitleCue: Codable, Equatable, Sendable {
    let start: TimeInterval
    let end: TimeInterval
    let text: String
}

/// Where the inspector's subtitles come from. Declared in priority order.
enum SubtitleSourceKind: String, Codable, CaseIterable, Sendable {
    case subtitleFile
    case alignedText
    /// Generated from the audio on this Mac, only when the user asks for it.
    case fromAudio
}

enum SubtitleFileFormat: String, Codable, CaseIterable, Sendable {
    case srt
    case vtt
    case lrc

    init?(pathExtension: String) {
        self.init(rawValue: pathExtension.lowercased())
    }
}

/// A recognized word with its position in the audio.
struct TranscribedWord: Codable, Equatable, Sendable {
    let text: String
    let start: TimeInterval
    let end: TimeInterval
}

/// Words recognized from one version of the audio. Cached so a new text or a source switch
/// does not run recognition again.
struct RecognizedSpeech: Codable, Equatable, Sendable {
    let audioSHA256: String
    let words: [TranscribedWord]
}

/// A subtitle file the user attached; the copy lives in the Subtitles folder.
struct AttachedSubtitleFile: Codable, Equatable, Sendable {
    let displayName: String
    let format: SubtitleFileFormat
    let sha256: String
}

/// The inputs that produced `<project id>.srt`, so it is rebuilt only when one of them changes.
struct SubtitleProvenance: Codable, Equatable, Sendable {
    let source: SubtitleSourceKind
    let inputSHA256: String
    let audioSHA256: String?
}

/// Outcome of the last text alignment. A failed alignment is not retried until the text or
/// the audio changes.
struct TextAlignmentRecord: Codable, Equatable, Sendable {
    let textSHA256: String
    let audioSHA256: String
    let matchRatio: Double

    var succeeded: Bool {
        matchRatio >= TextAligner.minimumMatchRatio
    }
}

/// Subtitles generated from the audio. The cues are kept in `<project id>.srt` while this is the
/// current source and can be rebuilt from the cached words after switching away.
struct GeneratedSubtitlesRecord: Codable, Equatable, Sendable {
    let audioSHA256: String
}

/// `<project id>.json` in the Subtitles folder. The database schema is not involved.
struct SubtitleManifest: Codable, Equatable, Sendable {
    static let currentVersion = 1

    var version: Int = Self.currentVersion
    var selectedSource: SubtitleSourceKind?
    var attachedFile: AttachedSubtitleFile?
    var current: SubtitleProvenance?
    var lastAlignment: TextAlignmentRecord?
    var generated: GeneratedSubtitlesRecord?
}

/// The attached plain-text script as the subtitles feature sees it.
struct SubtitleScript: Equatable, Sendable {
    let text: String
    let displayName: String
}

enum SubtitleSourcePlanner {
    /// Sources this project can show, in priority order.
    static func availableSources(
        manifest: SubtitleManifest,
        hasScript: Bool
    ) -> [SubtitleSourceKind] {
        SubtitleSourceKind.allCases.filter { kind in
            switch kind {
            case .subtitleFile:
                manifest.attachedFile != nil
            case .alignedText:
                hasScript
            case .fromAudio:
                manifest.generated != nil
            }
        }
    }

    /// The user's choice when it is still available, otherwise the highest-priority source.
    static func activeSource(
        manifest: SubtitleManifest,
        available: [SubtitleSourceKind]
    ) -> SubtitleSourceKind? {
        if let selected = manifest.selectedSource, available.contains(selected) {
            return selected
        }
        return available.first
    }
}

enum ContentHash {
    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func sha256(_ text: String) -> String {
        sha256(Data(text.utf8))
    }
}

/// Persists subtitles under `Application Support/Shadowing/Subtitles`.
protocol SubtitleStoring: Sendable {
    func manifest(projectID: UUID) async throws -> SubtitleManifest
    func saveManifest(_ manifest: SubtitleManifest, projectID: UUID) async throws
    /// Copies a user-chosen subtitle file into the Subtitles folder. The original is only read.
    func importSubtitleFile(from url: URL, projectID: UUID) async throws -> AttachedSubtitleFile
    func attachedSubtitleText(projectID: UUID, format: SubtitleFileFormat) async throws -> String?
    /// Cues from `<project id>.srt`, or `nil` when it does not exist.
    func subtitles(projectID: UUID) async throws -> [SubtitleCue]?
    func saveSubtitles(_ cues: [SubtitleCue], projectID: UUID) async throws
    func recognizedSpeech(projectID: UUID) async throws -> RecognizedSpeech?
    func saveRecognizedSpeech(_ speech: RecognizedSpeech, projectID: UUID) async throws
}

/// Reads the practice audio behind its security-scoped bookmark. Read-only.
protocol SourceAudioAccessing: Sendable {
    func fingerprint(bookmark: Data) async throws -> String
    func withAudioFile<Value: Sendable>(
        bookmark: Data,
        _ operation: @Sendable (URL) async throws -> Value
    ) async throws -> Value
}

enum SpeechRecognitionEvent: Equatable, Sendable {
    case downloadingModel(fraction: Double)
    /// Newly finalized words and how far into the audio recognition has got (0...1).
    case recognized(words: [TranscribedWord], progress: Double)
}

/// English speech recognition that runs on this Mac. Audio never leaves the device.
protocol SpeechRecognizing: Sendable {
    func recognize(
        audioURL: URL,
        duration: TimeInterval
    ) -> AsyncThrowingStream<SpeechRecognitionEvent, any Error>
}

enum SpeechRecognitionError: Error, Equatable, LocalizedError, Sendable {
    case unavailable
    case unreadableAudio(String)
    case noSpeech

    var errorDescription: String? {
        switch self {
        case .unavailable:
            String(localized: "English speech recognition isn't available on this Mac.")
        case let .unreadableAudio(reason):
            String(localized: "The audio could not be read for speech recognition: \(reason)")
        case .noSpeech:
            String(localized: "No English speech was recognized in this audio.")
        }
    }
}

protocol SubtitleFileChoosing: Sendable {
    /// Asks for an .srt, .vtt or .lrc file; `includingText` also allows a .txt script.
    @MainActor
    func chooseSubtitleFile(includingText: Bool) async -> URL?
    /// Asks where to save an exported .srt.
    @MainActor
    func chooseExportDestination(suggestedName: String) async -> URL?
}
