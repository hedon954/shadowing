import Foundation

enum PracticeAudioCommand: Equatable, Sendable {
    case loadSource(URL)
    case playOriginal(region: PracticeRegion?, from: TimeInterval, rate: Double)
    /// Plays the region once without looping, then reports `segmentFinished`.
    case playOriginalSegment(region: PracticeRegion, from: TimeInterval, rate: Double)
    case playTake(takeID: UUID, from: TimeInterval, loop: PracticeRegion?)
    /// Plays part of a take once (take-file time), then reports `segmentFinished`.
    case playTakeSegment(takeID: UUID, region: PracticeRegion)
    case playTogether(region: PracticeRegion, takeID: UUID, rate: Double)
    case pause
    case seek(TimeInterval)
    case setRate(Double)
    case setVolume(Float)
    case setLoop(PracticeRegion?)
    case beginRecording(region: PracticeRegion, destinationURL: URL, playOriginal: Bool)
    case stopRecording
    /// Tears down an armed/active recording without committing a Take.
    case abortRecording
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

struct TimedWaveformEnvelopePoint: Equatable, Sendable {
    let time: TimeInterval
    let envelope: WaveformEnvelopePoint
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
    /// The main track (or a looping/plain take playback) reached its end.
    case playbackFinished
    /// A one-shot segment (`playOriginalSegment` / `playTakeSegment`) finished.
    /// The main track did not end; never handle this as end-of-track.
    case segmentFinished
    case recordingStarted
    case recordingProgress(TimeInterval)
    case recordingEnvelope([TimedWaveformEnvelopePoint])
    /// Seconds into the take file where the original starts (see `RecordingAlignment`).
    case recordingAlignmentMeasured(TimeInterval)
    case recordingFinished(url: URL, duration: TimeInterval, reason: RecordingStopReason)
    /// The take ended without any microphone audio; nothing was saved.
    case recordingNoAudio
    case interrupted(PracticeAudioInterruption)
    case failed(PracticeAudioFailure)
}

protocol PracticeAudioClient: Sendable {
    func execute(_ command: PracticeAudioCommand) async throws
    /// A new stream per call: cancelling one subscriber's loop must not end the others'.
    func eventStream() async -> AsyncStream<PracticeAudioEvent>
}
