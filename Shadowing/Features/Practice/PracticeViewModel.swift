import Combine
import Foundation

struct PracticeFailure: Equatable, Identifiable, Sendable {
    let id = UUID()
    let message: String

    static func == (lhs: PracticeFailure, rhs: PracticeFailure) -> Bool {
        lhs.message == rhs.message
    }
}

struct PracticeLeaveConfirmation: Equatable, Identifiable, Sendable {
    let id = UUID()
}

enum PracticeIntent: Equatable, Sendable {
    case togglePlayback
    case pause
    case seek(TimeInterval)
    case jump(TimeInterval)
    case selectRegion(PracticeRegion)
    case clearRegion
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
             .clearRegion,
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
    static let maximumLiveEnvelopePointCount = 12000

    @Published var project: AudioProject {
        didSet {
            if project.currentRegion != oldValue.currentRegion {
                refreshPlayheadSentence()
            }
        }
    }

    @Published private(set) var waveform: WaveformPresentation
    @Published var isPlaying = false
    /// Not published: it ticks while playing. Views read `playheadClock` (cursor, time) or
    /// `playheadSentence` (changes only when the sentence changes).
    var playhead: TimeInterval {
        didSet {
            guard playhead != oldValue else {
                return
            }
            playheadClock.position = playhead
            refreshPlayheadSentence()
        }
    }

    let playheadClock: PlayheadClock
    @Published var playheadSentence = PlayheadSentence()
    @Published private(set) var rate: Double = 1
    @Published private(set) var volume: Double = 0.8
    @Published var loopEnabled = false
    @Published var interactionPhase = PracticeInteractionPhase.practicing
    @Published var recordingPresentation = RecordingPresentation.idle
    @Published var liveRecordingPeaks: [Float] = []
    @Published var liveRecordingEnvelope: [TimedWaveformEnvelopePoint] = []
    @Published var activeTake: Take?
    @Published var takes: [Take] = []
    @Published var selectedTakePeaks: [Float] = []
    @Published var takeWaveforms: [UUID: WaveformPresentation] = [:]
    /// Per-Take loop selections on the source timeline (independent of Original practice region).
    @Published var takeLoopSelections: [UUID: PracticeRegion] = [:]
    @Published var playingTakeID: UUID?
    @Published var timelineViewport: TimelineViewport {
        didSet {
            timelineViewportDidChange(from: oldValue)
        }
    }

    /// True while the user drags on the waveform: no automatic pan or zoom until release.
    var suspendPlayheadFollow = false
    /// The reveal held back during that drag, applied once on release.
    var deferredTimelineReveal: DeferredTimelineReveal?
    /// Active-jump signal for the waveform and transcript (see `JumpReveal`). Not published
    /// itself: noting the user's transcript scroll must not redraw the practice view (that fed
    /// the transcript layout loop). Only a token bump is published, as `revealToken`.
    var jumpReveal = JumpReveal() {
        didSet {
            if jumpReveal.token != revealToken {
                revealToken = jumpReveal.token
            }
        }
    }

    @Published private(set) var revealToken = 0
    @Published var lastRecordingStopReason: RecordingStopReason?
    @Published var microphonePermissionPrompt: MicrophonePermissionState?
    /// Last microphone access read (refreshed whenever the app becomes active); `nil` until read.
    @Published var microphonePermission: MicrophonePermissionState?
    @Published var recordingNotice: String?
    @Published var failure: PracticeFailure?
    /// A take that ended without audio; offers Try Again.
    @Published var recordingIssue: RecordingIssue?
    @Published var leaveConfirmation: PracticeLeaveConfirmation?
    @Published var scriptText: String?
    /// Sentences found from pauses in the original; used when there are no timed subtitles.
    @Published var sentenceChunks: [SentenceChunk] = [] {
        didSet {
            refreshPlayheadSentence()
        }
    }

    /// Measured take offsets (`RecordingAlignment`); missing means 0.
    @Published var takeOffsets: [UUID: TimeInterval] = [:]
    /// The window's undo manager, for "Undo Delete Take N" (set by `PracticeView`).
    weak var undoManager: UndoManager?
    /// The running "compare" playback, if any.
    @Published var comparison: ComparisonPlayback? {
        didSet {
            refreshPlayheadSentence()
        }
    }

    /// Non-nil while a post-Compare engine seek is in flight; ignore late playheadChanged.
    var restoringPlayheadAfterComparison: TimeInterval?
    /// Non-nil while a seek this view model issued (click, selection) is not yet applied by the
    /// engine: positions the engine reports meanwhile are from before the jump, and following
    /// them panned the waveform back toward the old playhead (then again to the new one).
    var pendingLocalSeek: TimeInterval?
    @Published var compareMode = CompareMode.originalThenMine

    let audioClient: any PracticeAudioClient
    let projects: any ProjectRepository
    let sessionPreparer: any PracticeSessionPreparing
    let recordingDependencies: RecordingDependencies?
    let textFileChooser: (any TextFileChoosing)?
    let subtitles: SubtitlesViewModel
    let comparisonScheduler: any ComparisonPlaybackScheduler
    let pauseChunks: any PauseChunkProviding
    var eventTask: Task<Void, Never>?
    var commandTask: Task<Void, Never>?
    var recordingTask: Task<Void, Never>?
    var finalizationTask: Task<Void, Never>?
    /// Ends "Saving recording…" with an error if the engine doesn't close the file in time.
    var savingWatchdogTask: Task<Void, Never>?
    /// Tests can shorten this.
    var savingTimeout: Duration = .seconds(3)
    var appActivationTask: Task<Void, Never>?
    var recordingContext: PendingRecordingContext?
    /// Independent of practice loop selection; spans playhead → source end while recording.
    @Published var recordingWindow: PracticeRegion?
    var recordingTimelineRate: Double = 1
    private var hasStarted = false
    var hasClosed = false
    /// Set once hydrate restored the saved loop state and visible range; only then are they saved.
    var restoredSession = false
    var playheadPersistTask: Task<Void, Never>?
    var leaveAfterFinalize: (@MainActor () -> Void)?
    /// Tests can shorten this; production uses a short debounce for playhead writes.
    var playheadPersistDelay: Duration = .milliseconds(400)

    var region: PracticeRegion? {
        project.currentRegion
    }

    var isComparing: Bool {
        !takes.isEmpty
    }

    var showsMultiTrackWorkspace: Bool {
        !takes.isEmpty || recordingPresentation != .idle
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
        recordingDependencies: RecordingDependencies? = nil,
        textFileChooser: (any TextFileChoosing)? = nil,
        subtitleDependencies: SubtitleDependencies? = nil,
        comparisonScheduler: any ComparisonPlaybackScheduler = ContinuousComparisonPlaybackScheduler(),
        pauseChunks: any PauseChunkProviding = ComputedPauseChunks()
    ) {
        project = prepared.project
        waveform = prepared.waveform
        playhead = prepared.project.playhead
        playheadClock = PlayheadClock(position: prepared.project.playhead)
        timelineViewport = .full(sourceDuration: prepared.project.duration)
        rate = Self.normalizedRate(prepared.project.playbackRate)
        self.audioClient = audioClient
        self.projects = projects
        self.sessionPreparer = sessionPreparer
        self.recordingDependencies = recordingDependencies
        self.textFileChooser = textFileChooser
        self.comparisonScheduler = comparisonScheduler
        self.pauseChunks = pauseChunks
        subtitles = SubtitlesViewModel(project: prepared.project, dependencies: subtitleDependencies)
        subtitles.onError = { [weak self] error in
            self?.show(error)
        }
        subtitles.onTextChosen = { [weak self] url in
            self?.attachScript(from: url)
        }
        subtitles.onDisplayChanged = { [weak self] in
            self?.refreshPlayheadSentence()
        }
        refreshPlayheadSentence()
    }

    deinit {
        eventTask?.cancel()
        commandTask?.cancel()
        recordingTask?.cancel()
        finalizationTask?.cancel()
        appActivationTask?.cancel()
        playheadPersistTask?.cancel()
    }

    func start() {
        guard !hasStarted else {
            return
        }
        hasStarted = true
        // Subscribed here, synchronously: events sent before the task first runs are buffered,
        // not lost.
        let stream = audioClient.eventStream()
        eventTask = Task { [weak self] in
            for await event in stream {
                guard !Task.isCancelled else {
                    return
                }
                self?.receive(event)
            }
        }
        setVolume(volume)
        setRate(rate)
        Task { [weak self] in
            await self?.hydrateRestoredSession()
        }
        loadSentenceChunks()
        observeAppActivation()
    }

    func send(_ intent: PracticeIntent) {
        guard !hasClosed,
              !controlsLocked || !intent.requiresUnlockedTransport
        else {
            return
        }
        cancelComparison(for: intent)

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
        case .clearRegion:
            clearRegionCommand()
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

    func clearRegion() {
        send(.clearRegion)
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
        pauseTakePlaybackIfNeeded()
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
                self?.persistProjectImmediately()
            }
        }
    }

    private func pauseCommand() {
        guard isPlaying || playingTakeID != nil else {
            return
        }
        playingTakeID = nil
        performVoidCommand { [audioClient] in
            try await audioClient.execute(.pause)
        } completion: { [weak self] in
            self?.isPlaying = false
            self?.persistProjectImmediately()
        }
    }

    private func seekCommand(to position: TimeInterval) {
        restoringPlayheadAfterComparison = nil
        let clamped = min(max(position, 0), project.duration)
        let disablesLoop = loopEnabled &&
            region.map { !($0.start ..< $0.end ~= clamped) } == true
        if disablesLoop {
            loopEnabled = false
        }
        playhead = clamped
        pendingLocalSeek = clamped
        revealPlayhead()
        performVoidCommand(seekGate: clamped) { [audioClient] in
            if disablesLoop {
                try await audioClient.execute(.setLoop(nil))
            }
            try await audioClient.execute(.seek(clamped))
        } completion: { [weak self] in
            self?.persistProjectImmediately()
        }
    }

    private func selectRegionCommand(_ region: PracticeRegion) {
        guard region.end <= project.duration else {
            show(DomainError.invalidTimeRange)
            return
        }
        project.currentRegion = region
        loopEnabled = true
        let resumeInsideLoop = isPlaying
            && playingTakeID == nil
            && playhead >= region.start
            && playhead < region.end
        let nextPlayhead = resumeInsideLoop ? playhead : region.start
        playhead = nextPlayhead
        project.playhead = nextPlayhead
        pendingLocalSeek = nextPlayhead
        // Released from a waveform drag: the release reveal aims at where playback continues
        // (this selection and its start), never at the playhead it is about to leave.
        _ = deferTimelineMoveDuringGesture(focus: region)
        performVoidCommand(seekGate: nextPlayhead) { [audioClient] in
            try await audioClient.execute(.setLoop(region))
            try await audioClient.execute(.seek(nextPlayhead))
        } completion: { [weak self] in
            self?.persistProjectImmediately()
        }
    }

    private func clearRegionCommand() {
        guard region != nil else {
            return
        }
        project.currentRegion = nil
        loopEnabled = false
        performVoidCommand { [audioClient] in
            try await audioClient.execute(.setLoop(nil))
        } completion: { [weak self] in
            self?.persistProjectImmediately()
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
        project.playbackRate = newRate
        performVoidCommand { [audioClient] in
            try await audioClient.execute(.setRate(newRate))
        } completion: { [weak self] in
            self?.persistProjectImmediately()
        }
    }

    private func setVolumeCommand(_ newVolume: Double) {
        let clamped = min(max(newVolume, 0), 1)
        volume = clamped
        performVoidCommand { [audioClient] in
            try await audioClient.execute(.setVolume(Float(clamped)))
        }
    }

    func dismissFailure() {
        failure = nil
    }

    func show(_ error: Error) {
        failure = PracticeFailure(message: error.localizedDescription)
    }

    static func normalizedRate(_ rate: Double) -> Double {
        supportedRates.contains(rate) ? rate : 1
    }
}
