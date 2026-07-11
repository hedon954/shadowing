import Foundation

enum PracticeAudioCommand: Equatable, Sendable {
    case loadSource(URL)
    case playOriginal(region: PracticeRegion?, from: TimeInterval, rate: Double)
    case playTake(takeID: UUID, from: TimeInterval)
    case pause
    case seek(TimeInterval)
    case setRate(Double)
    case setVolume(Float)
    case setLoop(PracticeRegion?)
    case beginRecording(region: PracticeRegion, destinationURL: URL, playOriginal: Bool)
    case stopRecording
}

enum PracticeAudioOperation: Equatable, Sendable {
    case loading
    case playback
    case recording
}

enum PracticeAudioInterruption: Equatable, Sendable {
    case systemInterruption
    case inputDeviceRemoved
    case outputDeviceChanged
}

struct PracticeAudioFailure: Error, Equatable, LocalizedError, Sendable {
    let operation: PracticeAudioOperation
    let message: String

    var errorDescription: String? {
        message
    }
}

struct LoadedAudioSource: Equatable, Sendable {
    let duration: TimeInterval
    let sampleRate: Double
    let frameCount: Int64
}

enum RecordingStopReason: Equatable, Sendable {
    case manual
    case regionEnd
    case systemInterruption
    case inputDeviceRemoved
    case writeFailure
}

enum PracticeAudioEvent: Equatable, Sendable {
    case sourceLoaded(LoadedAudioSource)
    case playheadChanged(TimeInterval)
    case playbackFinished
    case recordingStarted
    case recordingProgress(TimeInterval)
    case recordingPeaks([Float])
    case recordingFinished(url: URL, duration: TimeInterval, reason: RecordingStopReason)
    case interrupted(PracticeAudioInterruption)
    case failed(PracticeAudioFailure)
}

protocol PracticeAudioClient: Sendable {
    func execute(_ command: PracticeAudioCommand) async throws
    func eventStream() async -> AsyncStream<PracticeAudioEvent>
}
