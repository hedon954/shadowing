import Foundation

enum MicrophonePermissionState: Equatable, Sendable {
    case notDetermined
    case authorized
    case denied
    case restricted
}

protocol MicrophonePermissionService: Sendable {
    func authorizationStatus() async -> MicrophonePermissionState
    func requestAuthorization() async -> MicrophonePermissionState
    func openSystemSettings() async
}

protocol RecordingCountdownClock: Sendable {
    func waitForNextSecond() async throws
}

protocol RecordingFileValidating: Sendable {
    func validatePlayableRecording(at url: URL) throws
}
