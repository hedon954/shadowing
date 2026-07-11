import Foundation

enum PlaybackTransport: Equatable, Sendable {
    case stopped(at: TimeInterval)
    case playing(at: TimeInterval)
    case paused(at: TimeInterval)

    var position: TimeInterval {
        switch self {
        case let .stopped(position), let .playing(position), let .paused(position):
            position
        }
    }
}

struct PracticeState: Equatable, Sendable {
    let projectID: UUID
    var region: PracticeRegion?
    var transport: PlaybackTransport
}

enum RecordingPhase: Equatable, Sendable {
    case preparing
    case countingDown(remainingSeconds: Int)
    case capturing(elapsed: TimeInterval)
    case finalizing
}

struct RecordingState: Equatable, Sendable {
    let projectID: UUID
    let region: PracticeRegion
    var phase: RecordingPhase
}

enum ComparisonMode: Equatable, Sendable {
    case original
    case selectedTake
}

struct ComparisonState: Equatable, Sendable {
    let projectID: UUID
    var region: PracticeRegion
    var selectedTake: Take
    var mode: ComparisonMode
    var transport: PlaybackTransport
}

enum PracticeSessionState: Equatable, Sendable {
    case idle
    case practicing(PracticeState)
    case recording(RecordingState)
    case comparing(ComparisonState)

    var kind: PracticeSessionStateKind {
        switch self {
        case .idle:
            .idle
        case .practicing:
            .practicing
        case .recording:
            .recording
        case .comparing:
            .comparing
        }
    }
}

enum PracticeSessionStateKind: Equatable, Sendable {
    case idle
    case practicing
    case recording
    case comparing
}

enum PracticeSessionIntent: Sendable {
    case openProject(AudioProject)
    case selectRegion(PracticeRegion)
    case play(at: TimeInterval)
    case pause
    case updatePlayhead(TimeInterval)
    case prepareRecording
    case beginCountdown(seconds: Int)
    case countdownTick(remainingSeconds: Int)
    case updateRecordingElapsed(TimeInterval)
    case stopRecording
    case recordingCommitted(Take)
    case recordingDiscarded
    case selectTake(Take)
    case selectComparisonMode(ComparisonMode)
    case rerecord
    case returnToPractice
    case closeProject

    var kind: PracticeSessionIntentKind {
        switch self {
        case .openProject:
            .openProject
        case .selectRegion:
            .selectRegion
        case .play:
            .play
        case .pause:
            .pause
        case .updatePlayhead:
            .updatePlayhead
        case .prepareRecording:
            .prepareRecording
        case .beginCountdown:
            .beginCountdown
        case .countdownTick:
            .countdownTick
        case .updateRecordingElapsed:
            .updateRecordingElapsed
        case .stopRecording:
            .stopRecording
        case .recordingCommitted:
            .recordingCommitted
        case .recordingDiscarded:
            .recordingDiscarded
        case .selectTake:
            .selectTake
        case .selectComparisonMode:
            .selectComparisonMode
        case .rerecord:
            .rerecord
        case .returnToPractice:
            .returnToPractice
        case .closeProject:
            .closeProject
        }
    }
}

enum PracticeSessionIntentKind: Equatable, Sendable {
    case openProject
    case selectRegion
    case play
    case pause
    case updatePlayhead
    case prepareRecording
    case beginCountdown
    case countdownTick
    case updateRecordingElapsed
    case stopRecording
    case recordingCommitted
    case recordingDiscarded
    case selectTake
    case selectComparisonMode
    case rerecord
    case returnToPractice
    case closeProject
}

enum PracticeSessionEvent: Equatable, Sendable {
    case projectOpened(projectID: UUID)
    case regionChanged(PracticeRegion)
    case originalPlaybackRequested(region: PracticeRegion?, at: TimeInterval)
    case comparisonPlaybackRequested(mode: ComparisonMode, takeID: UUID, at: TimeInterval)
    case playbackPauseRequested
    case recordingPreparationRequested(region: PracticeRegion)
    case recordingCaptureRequested(region: PracticeRegion)
    case recordingStopRequested
    case comparisonReady(takeID: UUID)
    case selectedTakeChanged(takeID: UUID)
    case projectClosed
}

enum PracticeTransitionError: Error, Equatable, LocalizedError, Sendable {
    case invalidTransition(from: PracticeSessionStateKind, intent: PracticeSessionIntentKind)
    case missingPracticeRegion
    case invalidTime
    case invalidCountdown
    case takeDoesNotMatchRecording

    var errorDescription: String? {
        switch self {
        case let .invalidTransition(state, intent):
            "Cannot handle \(intent) while the practice session is \(state)."
        case .missingPracticeRegion:
            "Select a practice region before recording."
        case .invalidTime:
            "The practice session received an invalid time."
        case .invalidCountdown:
            "The recording countdown must be zero or greater."
        case .takeDoesNotMatchRecording:
            "The completed take does not match the active recording."
        }
    }
}

struct PracticeSessionStateMachine: Sendable {
    private(set) var state: PracticeSessionState = .idle

    @discardableResult
    mutating func handle(_ intent: PracticeSessionIntent) throws -> [PracticeSessionEvent] {
        if case .closeProject = intent {
            guard state != .idle else {
                return []
            }
            state = .idle
            return [.projectClosed]
        }

        switch state {
        case .idle:
            return try handleIdle(intent)
        case let .practicing(practice):
            return try handlePracticing(practice, intent: intent)
        case let .recording(recording):
            return try handleRecording(recording, intent: intent)
        case let .comparing(comparison):
            return try handleComparing(comparison, intent: intent)
        }
    }

    private mutating func handleIdle(
        _ intent: PracticeSessionIntent
    ) throws -> [PracticeSessionEvent] {
        guard case let .openProject(project) = intent else {
            throw transitionError(for: intent)
        }
        state = .practicing(
            PracticeState(
                projectID: project.id,
                region: project.currentRegion,
                transport: .stopped(at: project.playhead)
            )
        )
        return [.projectOpened(projectID: project.id)]
    }

    private mutating func handlePracticing(
        _ initialState: PracticeState,
        intent: PracticeSessionIntent
    ) throws -> [PracticeSessionEvent] {
        var practice = initialState
        switch intent {
        case let .selectRegion(region):
            practice.region = region
            practice.transport = .stopped(at: region.start)
            state = .practicing(
                practice
            )
            return [.regionChanged(region)]

        case let .play(position):
            try validate(time: position)
            practice.transport = .playing(at: position)
            state = .practicing(practice)
            return [.originalPlaybackRequested(region: practice.region, at: position)]

        case .pause:
            practice.transport = .paused(at: practice.transport.position)
            state = .practicing(practice)
            return [.playbackPauseRequested]

        case let .updatePlayhead(position):
            try validate(time: position)
            practice.transport = transport(practice.transport, updatedTo: position)
            state = .practicing(practice)
            return []

        case .prepareRecording:
            guard let region = practice.region else {
                throw PracticeTransitionError.missingPracticeRegion
            }
            state = .recording(
                RecordingState(projectID: practice.projectID, region: region, phase: .preparing)
            )
            return [.recordingPreparationRequested(region: region)]

        default:
            throw transitionError(for: intent)
        }
    }

    private mutating func handleRecording(
        _ initialState: RecordingState,
        intent: PracticeSessionIntent
    ) throws -> [PracticeSessionEvent] {
        var recording = initialState
        switch intent {
        case let .beginCountdown(seconds):
            return try beginCountdown(seconds, recording: recording, intent: intent)

        case let .countdownTick(remainingSeconds):
            return try tickCountdown(
                remainingSeconds,
                recording: recording,
                intent: intent
            )

        case let .updateRecordingElapsed(elapsed):
            guard case .capturing = recording.phase else {
                throw transitionError(for: intent)
            }
            try validate(time: elapsed)
            recording.phase = .capturing(elapsed: elapsed)
            state = .recording(recording)
            return []

        case .stopRecording:
            guard case .capturing = recording.phase else {
                throw transitionError(for: intent)
            }
            recording.phase = .finalizing
            state = .recording(recording)
            return [.recordingStopRequested]

        case let .recordingCommitted(take):
            return try completeRecording(take, recording: recording)

        case .recordingDiscarded:
            return discardRecording(recording)

        default:
            throw transitionError(for: intent)
        }
    }

    private mutating func beginCountdown(
        _ seconds: Int,
        recording: RecordingState,
        intent: PracticeSessionIntent
    ) throws -> [PracticeSessionEvent] {
        guard recording.phase == .preparing else {
            throw transitionError(for: intent)
        }
        return try updateCountdown(seconds, recording: recording)
    }

    private mutating func tickCountdown(
        _ remainingSeconds: Int,
        recording: RecordingState,
        intent: PracticeSessionIntent
    ) throws -> [PracticeSessionEvent] {
        guard case .countingDown = recording.phase else {
            throw transitionError(for: intent)
        }
        return try updateCountdown(remainingSeconds, recording: recording)
    }

    private mutating func updateCountdown(
        _ remainingSeconds: Int,
        recording initialState: RecordingState
    ) throws -> [PracticeSessionEvent] {
        guard remainingSeconds >= 0 else {
            throw PracticeTransitionError.invalidCountdown
        }
        var recording = initialState
        if remainingSeconds == 0 {
            recording.phase = .capturing(elapsed: 0)
            state = .recording(recording)
            return [.recordingCaptureRequested(region: recording.region)]
        }
        recording.phase = .countingDown(remainingSeconds: remainingSeconds)
        state = .recording(recording)
        return []
    }

    private mutating func completeRecording(
        _ take: Take,
        recording: RecordingState
    ) throws -> [PracticeSessionEvent] {
        guard recording.phase == .finalizing,
              take.projectID == recording.projectID,
              take.region == recording.region
        else {
            throw PracticeTransitionError.takeDoesNotMatchRecording
        }
        state = .comparing(
            ComparisonState(
                projectID: recording.projectID,
                region: recording.region,
                selectedTake: take,
                mode: .selectedTake,
                transport: .stopped(at: 0)
            )
        )
        return [.comparisonReady(takeID: take.id)]
    }

    private mutating func discardRecording(
        _ recording: RecordingState
    ) -> [PracticeSessionEvent] {
        state = .practicing(
            PracticeState(
                projectID: recording.projectID,
                region: recording.region,
                transport: .stopped(at: recording.region.start)
            )
        )
        return []
    }

    private mutating func handleComparing(
        _ initialState: ComparisonState,
        intent: PracticeSessionIntent
    ) throws -> [PracticeSessionEvent] {
        var comparison = initialState
        switch intent {
        case let .play(position):
            try validate(time: position)
            comparison.transport = .playing(at: position)
            state = .comparing(comparison)
            return [.comparisonPlaybackRequested(
                mode: comparison.mode,
                takeID: comparison.selectedTake.id,
                at: position
            )]

        case .pause:
            comparison.transport = .paused(at: comparison.transport.position)
            state = .comparing(comparison)
            return [.playbackPauseRequested]

        case let .updatePlayhead(position):
            try validate(time: position)
            comparison.transport = transport(comparison.transport, updatedTo: position)
            state = .comparing(comparison)
            return []

        case let .selectTake(take):
            guard take.projectID == comparison.projectID else {
                throw PracticeTransitionError.takeDoesNotMatchRecording
            }
            comparison.selectedTake = take
            comparison.region = take.region
            comparison.transport = .stopped(at: 0)
            state = .comparing(comparison)
            return [.selectedTakeChanged(takeID: take.id)]

        case let .selectComparisonMode(mode):
            comparison.mode = mode
            comparison.transport = .stopped(at: 0)
            state = .comparing(comparison)
            return []

        case .rerecord:
            state = .recording(
                RecordingState(
                    projectID: comparison.projectID,
                    region: comparison.region,
                    phase: .preparing
                )
            )
            return [.recordingPreparationRequested(region: comparison.region)]

        case .returnToPractice:
            state = .practicing(
                PracticeState(
                    projectID: comparison.projectID,
                    region: comparison.region,
                    transport: .stopped(at: comparison.region.start)
                )
            )
            return []

        default:
            throw transitionError(for: intent)
        }
    }

    private func transitionError(for intent: PracticeSessionIntent) -> PracticeTransitionError {
        .invalidTransition(from: state.kind, intent: intent.kind)
    }

    private func validate(time: TimeInterval) throws {
        guard time.isFinite, time >= 0 else {
            throw PracticeTransitionError.invalidTime
        }
    }

    private func transport(
        _ transport: PlaybackTransport,
        updatedTo position: TimeInterval
    ) -> PlaybackTransport {
        switch transport {
        case .stopped:
            .stopped(at: position)
        case .playing:
            .playing(at: position)
        case .paused:
            .paused(at: position)
        }
    }
}
