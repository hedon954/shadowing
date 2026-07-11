import Combine
import Foundation

struct PracticeFailure: Equatable, Identifiable, Sendable {
    let id = UUID()
    let message: String

    static func == (lhs: PracticeFailure, rhs: PracticeFailure) -> Bool {
        lhs.message == rhs.message
    }
}

enum PracticeIntent: Equatable, Sendable {
    case togglePlayback
    case pause
    case seek(TimeInterval)
    case jump(TimeInterval)
    case selectRegion(PracticeRegion)
    case setLoop(Bool)
    case setRate(Double)
    case setVolume(Double)

    var requiresUnlockedTransport: Bool {
        switch self {
        case .setVolume:
            false
        case .togglePlayback,
             .pause,
             .seek,
             .jump,
             .selectRegion,
             .setLoop,
             .setRate:
            true
        }
    }
}

enum PracticeInteractionPhase: Equatable, Sendable {
    case practicing
    case recording
}

@MainActor
final class PracticeViewModel: ObservableObject {
    static let supportedRates: [Double] = [0.5, 0.75, 1, 1.25, 1.5]
    static let maximumLivePeakCount = 360

    @Published var project: AudioProject
    @Published private(set) var waveform: WaveformPresentation
    @Published var isPlaying = false
    @Published var playhead: TimeInterval
    @Published private(set) var rate: Double = 1
    @Published private(set) var volume: Double = 0.8
    @Published private(set) var loopEnabled = false
    @Published var interactionPhase = PracticeInteractionPhase.practicing
    @Published var recordingPresentation = RecordingPresentation.idle
    @Published var liveRecordingPeaks: [Float] = []
    @Published var activeTake: Take?
    @Published var lastRecordingStopReason: RecordingStopReason?
    @Published var microphonePermissionPrompt: MicrophonePermissionState?
    @Published var recordingNotice: String?
    @Published var failure: PracticeFailure?

    let audioClient: any PracticeAudioClient
    let projects: any ProjectRepository
    private let sessionPreparer: any PracticeSessionPreparing
    let recordingDependencies: RecordingDependencies?
    private var eventTask: Task<Void, Never>?
    private var commandTask: Task<Void, Never>?
    var recordingTask: Task<Void, Never>?
    var finalizationTask: Task<Void, Never>?
    var recordingContext: PendingRecordingContext?
    private var hasStarted = false
    private var hasClosed = false

    var region: PracticeRegion? {
        project.currentRegion
    }

    var controlsLocked: Bool {
        interactionPhase == .recording || recordingPresentation.locksPracticeControls
    }

    var recordingWorkflowVisible: Bool {
        recordingPresentation != .idle
    }

    var canToggleLoop: Bool {
        region != nil && !controlsLocked
    }

    init(
        prepared: PreparedPractice,
        audioClient: any PracticeAudioClient,
        projects: any ProjectRepository,
        sessionPreparer: any PracticeSessionPreparing,
        recordingDependencies: RecordingDependencies? = nil
    ) {
        project = prepared.project
        waveform = prepared.waveform
        playhead = prepared.project.playhead
        self.audioClient = audioClient
        self.projects = projects
        self.sessionPreparer = sessionPreparer
        self.recordingDependencies = recordingDependencies
    }

    deinit {
        eventTask?.cancel()
        commandTask?.cancel()
        recordingTask?.cancel()
        finalizationTask?.cancel()
    }

    func start() {
        guard !hasStarted else {
            return
        }
        hasStarted = true
        eventTask = Task { [weak self, audioClient] in
            let stream = await audioClient.eventStream()
            for await event in stream {
                guard !Task.isCancelled else {
                    return
                }
                self?.receive(event)
            }
        }
        setVolume(volume)
    }

    func send(_ intent: PracticeIntent) {
        guard !hasClosed,
              !controlsLocked || !intent.requiresUnlockedTransport
        else {
            return
        }

        switch intent {
        case .togglePlayback:
            togglePlaybackCommand()
        case .pause:
            pauseCommand()
        case let .seek(position):
            seekCommand(to: position)
        case let .jump(offset):
            seekCommand(to: playhead + offset)
        case let .selectRegion(region):
            selectRegionCommand(region)
        case let .setLoop(enabled):
            setLoopCommand(enabled)
        case let .setRate(newRate):
            setRateCommand(newRate)
        case let .setVolume(newVolume):
            setVolumeCommand(newVolume)
        }
    }

    func togglePlayback() {
        send(.togglePlayback)
    }

    func pause() {
        send(.pause)
    }

    func seek(to position: TimeInterval) {
        send(.seek(position))
    }

    func jump(by offset: TimeInterval) {
        send(.jump(offset))
    }

    func selectRegion(_ region: PracticeRegion) {
        send(.selectRegion(region))
    }

    func setLoopEnabled(_ enabled: Bool) {
        send(.setLoop(enabled))
    }

    func setRate(_ newRate: Double) {
        send(.setRate(newRate))
    }

    func setVolume(_ newVolume: Double) {
        send(.setVolume(newVolume))
    }

    func setInteractionPhase(_ phase: PracticeInteractionPhase) {
        interactionPhase = phase
    }
}

extension PracticeViewModel {
    private func togglePlaybackCommand() {
        performCommand { [audioClient, isPlaying, loopEnabled, playhead, project, rate] in
            if isPlaying {
                try await audioClient.execute(.pause)
                return false
            }
            let position = playhead >= project.duration ? 0 : playhead
            try await audioClient.execute(
                .playOriginal(
                    region: loopEnabled ? project.currentRegion : nil,
                    from: position,
                    rate: rate
                )
            )
            return true
        } completion: { [weak self] playing in
            self?.isPlaying = playing
            if !playing {
                self?.persistPosition()
            }
        }
    }

    private func pauseCommand() {
        guard isPlaying else {
            return
        }
        performVoidCommand { [audioClient] in
            try await audioClient.execute(.pause)
        } completion: { [weak self] in
            self?.isPlaying = false
            self?.persistPosition()
        }
    }

    private func seekCommand(to position: TimeInterval) {
        let clamped = effectiveSeekPosition(position)
        playhead = clamped
        performVoidCommand { [audioClient] in
            try await audioClient.execute(.seek(clamped))
        } completion: { [weak self] in
            self?.persistPosition()
        }
    }

    private func selectRegionCommand(_ region: PracticeRegion) {
        guard region.end <= project.duration else {
            show(DomainError.invalidTimeRange)
            return
        }
        project.currentRegion = region
        project.playhead = region.start
        playhead = region.start
        loopEnabled = true
        performVoidCommand { [audioClient] in
            try await audioClient.execute(.setLoop(region))
            try await audioClient.execute(.seek(region.start))
        } completion: { [weak self] in
            self?.persistPosition()
        }
    }

    private func setLoopCommand(_ enabled: Bool) {
        guard let region else {
            loopEnabled = false
            return
        }
        guard loopEnabled != enabled else {
            return
        }
        loopEnabled = enabled
        performVoidCommand { [audioClient] in
            try await audioClient.execute(.setLoop(enabled ? region : nil))
        }
    }

    private func setRateCommand(_ newRate: Double) {
        guard Self.supportedRates.contains(newRate) else {
            return
        }
        rate = newRate
        performVoidCommand { [audioClient] in
            try await audioClient.execute(.setRate(newRate))
        }
    }

    private func setVolumeCommand(_ newVolume: Double) {
        let clamped = min(max(newVolume, 0), 1)
        volume = clamped
        performVoidCommand { [audioClient] in
            try await audioClient.execute(.setVolume(Float(clamped)))
        }
    }

    private func effectiveSeekPosition(_ requested: TimeInterval) -> TimeInterval {
        let clamped = min(max(requested, 0), project.duration)
        guard loopEnabled, let region else {
            return clamped
        }
        return region.start ..< region.end ~= clamped ? clamped : region.start
    }

    func dismissFailure() {
        failure = nil
    }

    func close() async {
        guard !hasClosed else {
            return
        }
        hasClosed = true
        recordingTask?.cancel()
        finalizationTask?.cancel()
        if case .countingDown = recordingPresentation {
            discardPendingRecording()
        }
        eventTask?.cancel()
        await commandTask?.value
        isPlaying = false

        var closeError: Error?
        do {
            try await audioClient.execute(.pause)
        } catch {
            closeError = error
        }
        do {
            project.playhead = min(max(playhead, 0), project.duration)
            try await projects.save(project)
        } catch {
            closeError = closeError ?? error
        }
        await sessionPreparer.endSession()
        if let closeError {
            show(closeError)
        }
    }

    private func receive(_ event: PracticeAudioEvent) {
        switch event {
        case .recordingStarted,
             .recordingProgress,
             .recordingPeaks,
             .recordingFinished:
            receiveRecordingEvent(event)
        default:
            receiveTransportEvent(event)
        }
    }

    private func receiveTransportEvent(_ event: PracticeAudioEvent) {
        switch event {
        case .sourceLoaded:
            break
        case let .playheadChanged(position):
            playhead = min(max(position, 0), project.duration)
        case .playbackFinished:
            isPlaying = false
            playhead = project.duration
            persistPosition()
        case let .interrupted(interruption):
            isPlaying = false
            if recordingPresentation.locksPracticeControls {
                recordingPresentation = .finalizing
                recordingNotice = interruption == .inputDeviceRemoved
                    ? "The microphone was disconnected. Saving the valid recorded portion."
                    : "Recording was interrupted. Saving the valid recorded portion."
            } else {
                show(
                    AudioSourceError.failed(
                        interruption == .outputDeviceChanged
                            ? "The audio output changed. Press Play to continue."
                            : "Playback was interrupted. Press Play to continue."
                    )
                )
            }
        case let .failed(audioFailure):
            isPlaying = false
            if audioFailure.operation == .recording {
                handleRecordingFailure(audioFailure, reason: .writeFailure)
            } else {
                show(audioFailure)
            }
        case .recordingStarted,
             .recordingProgress,
             .recordingPeaks,
             .recordingFinished:
            break
        }
    }

    private func receiveRecordingEvent(_ event: PracticeAudioEvent) {
        switch event {
        case .recordingStarted:
            recordingPresentation = .recording(elapsed: 0)
            playhead = recordingContext?.region.start ?? playhead
        case let .recordingProgress(elapsed):
            recordingPresentation = .recording(elapsed: elapsed)
            if let region = recordingContext?.region {
                playhead = min(region.start + elapsed * rate, region.end)
            }
        case let .recordingPeaks(peaks):
            appendLivePeaks(peaks)
        case let .recordingFinished(url, duration, reason):
            recordingPresentation = .finalizing
            finalizationTask?.cancel()
            finalizationTask = Task { [weak self] in
                await self?.finishRecording(url: url, duration: duration, reason: reason)
                self?.finalizationTask = nil
            }
        case .sourceLoaded,
             .playheadChanged,
             .playbackFinished,
             .interrupted,
             .failed:
            break
        }
    }

    private func persistPosition() {
        project.playhead = min(max(playhead, 0), project.duration)
        Task { [weak self, projects, project] in
            do {
                try await projects.save(project)
            } catch {
                self?.show(error)
            }
        }
    }

    private func performVoidCommand(
        _ operation: @escaping @Sendable () async throws -> Void,
        completion: @escaping @MainActor () -> Void = {}
    ) {
        let previousCommand = commandTask
        commandTask = Task { [weak self] in
            await previousCommand?.value
            guard !Task.isCancelled else {
                return
            }
            do {
                try await operation()
                try Task.checkCancellation()
                completion()
            } catch is CancellationError {
                return
            } catch {
                self?.show(error)
            }
        }
    }

    private func performCommand<Value: Sendable>(
        _ operation: @escaping @Sendable () async throws -> Value,
        completion: @escaping @MainActor (Value) -> Void
    ) {
        let previousCommand = commandTask
        commandTask = Task { [weak self] in
            await previousCommand?.value
            guard !Task.isCancelled else {
                return
            }
            do {
                let value = try await operation()
                try Task.checkCancellation()
                completion(value)
            } catch is CancellationError {
                return
            } catch {
                self?.show(error)
            }
        }
    }

    func show(_ error: Error) {
        failure = PracticeFailure(message: error.localizedDescription)
    }
}
