@preconcurrency import AVFoundation
import Foundation

enum RecordingValidationError: Error, Equatable, LocalizedError, Sendable {
    case unplayable(path: String, reason: String)
    case empty(path: String)

    var errorDescription: String? {
        switch self {
        case let .unplayable(path, reason):
            "The temporary recording at \(path) is not playable: \(reason)"
        case let .empty(path):
            "The temporary recording at \(path) contains no audio frames."
        }
    }
}

struct AVAudioRecordingFileValidator: RecordingFileValidating {
    func validatePlayableRecording(at url: URL) throws {
        let file: AVAudioFile
        do {
            file = try AVAudioFile(forReading: url)
        } catch {
            throw RecordingValidationError.unplayable(
                path: url.path,
                reason: error.localizedDescription
            )
        }
        guard file.length > 0, file.processingFormat.sampleRate > 0 else {
            throw RecordingValidationError.empty(path: url.path)
        }
    }
}
