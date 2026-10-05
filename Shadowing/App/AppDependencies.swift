import Foundation

@MainActor
final class AppDependencies {
    let fileChooser: any AudioFileChoosing
    let textFileChooser: any TextFileChoosing
    let projects: any ProjectRepository
    let takes: any TakeRepository
    let settings: any SettingsStore
    let audioClient: any PracticeAudioClient
    let sessionPreparer: any PracticeSessionPreparing
    let recording: RecordingDependencies
    let inputDevices: any AudioInputDeviceProviding
    let recordingsStorageURL: URL
    let subtitles: SubtitleDependencies?
    let pauseChunks: any PauseChunkProviding

    init(
        fileChooser: any AudioFileChoosing,
        textFileChooser: any TextFileChoosing,
        projects: any ProjectRepository,
        takes: any TakeRepository,
        settings: any SettingsStore,
        audioClient: any PracticeAudioClient,
        sessionPreparer: any PracticeSessionPreparing,
        recording: RecordingDependencies,
        inputDevices: any AudioInputDeviceProviding,
        recordingsStorageURL: URL,
        subtitles: SubtitleDependencies? = nil,
        pauseChunks: any PauseChunkProviding = ComputedPauseChunks()
    ) {
        self.fileChooser = fileChooser
        self.textFileChooser = textFileChooser
        self.projects = projects
        self.takes = takes
        self.settings = settings
        self.audioClient = audioClient
        self.sessionPreparer = sessionPreparer
        self.recording = recording
        self.inputDevices = inputDevices
        self.recordingsStorageURL = recordingsStorageURL
        self.subtitles = subtitles
        self.pauseChunks = pauseChunks
    }

    static func live(fileManager: FileManager = .default) throws -> AppDependencies {
        let applicationSupport = try Self.applicationSupportDirectory(fileManager: fileManager)
        let database = try AppDatabase.open(
            at: applicationSupport.appendingPathComponent("Shadowing.sqlite", isDirectory: false)
        )
        let projects = GRDBProjectRepository(database: database)
        let takes = GRDBTakeRepository(database: database)
        let settings = GRDBSettingsStore(database: database)
        let recordingsStorageURL = applicationSupport.appendingPathComponent(
            "Recordings",
            isDirectory: true
        )
        let recordingFiles = LocalRecordingFileStore(rootDirectory: recordingsStorageURL)
        Self.cleanupOrphanedTemporaryTakes(using: recordingFiles)
        let waveformDirectory = applicationSupport.appendingPathComponent("Waveforms", isDirectory: true)
        let waveformService = CachedWaveformService(cache: WaveformFileCache(directory: waveformDirectory))
        let audioClient = PracticeAudioEngine { takeID in
            guard let take = try await takes.take(id: takeID) else {
                throw PracticeAudioEngineError.takeResolutionUnavailable(takeID)
            }
            return try recordingFiles.audioURL(relativePath: take.relativeAudioPath)
        }
        let sessionPreparer = Self.makeSessionPreparer(
            projects: projects,
            settings: settings,
            audioClient: audioClient,
            waveformService: waveformService
        )
        return AppDependencies(
            fileChooser: SystemAudioFileChooser(),
            textFileChooser: SystemTextFileChooser(),
            projects: projects,
            takes: takes,
            settings: settings,
            audioClient: audioClient,
            sessionPreparer: sessionPreparer,
            recording: Self.makeRecordingDependencies(
                recordingFiles: recordingFiles,
                takes: takes,
                settings: settings,
                waveformService: waveformService
            ),
            inputDevices: SystemAudioInputDeviceService(),
            recordingsStorageURL: recordingsStorageURL,
            subtitles: SubtitleDependencies(
                store: LocalSubtitleFileStore(
                    directory: applicationSupport.appendingPathComponent("Subtitles", isDirectory: true)
                ),
                audio: BookmarkedSourceAudio(bookmarks: SecurityScopedBookmarkStore()),
                recognizer: Self.makeSpeechRecognizer(),
                fileChooser: SystemSubtitleFileChooser()
            ),
            pauseChunks: CachedPauseChunks(directory: waveformDirectory)
        )
    }

    /// Speech recognition for subtitles needs `SpeechAnalyzer` (macOS 26). Earlier systems
    /// show attached text without timing.
    private static func makeSpeechRecognizer() -> (any SpeechRecognizing)? {
        if #available(macOS 26, *) {
            return SpeechAnalyzerRecognizer()
        }
        return nil
    }

    private static func applicationSupportDirectory(fileManager: FileManager) throws -> URL {
        let environment = ProcessInfo.processInfo.environment
        let applicationSupport = try AppLaunchEnvironment.testDataDirectory(environment: environment)
            ?? fileManager.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            )
            .appendingPathComponent("Shadowing", isDirectory: true)
        try fileManager.createDirectory(
            at: applicationSupport,
            withIntermediateDirectories: true
        )
        return applicationSupport
    }

    private static func makeSessionPreparer(
        projects: GRDBProjectRepository,
        settings: GRDBSettingsStore,
        audioClient: PracticeAudioEngine,
        waveformService: CachedWaveformService
    ) -> AudioProjectSessionLoader {
        AudioProjectSessionLoader(
            projects: projects,
            bookmarks: SecurityScopedBookmarkStore(),
            validator: MP3FileValidator(),
            metadataLoader: AVAssetMetadataLoader(),
            waveformService: waveformService,
            audioClient: audioClient,
            settings: settings
        )
    }

    private static func makeRecordingDependencies(
        recordingFiles: LocalRecordingFileStore,
        takes: GRDBTakeRepository,
        settings: GRDBSettingsStore,
        waveformService: CachedWaveformService
    ) -> RecordingDependencies {
        RecordingDependencies(
            permissions: SystemMicrophonePermissionService(),
            countdownClock: ContinuousRecordingCountdownClock(),
            fileStore: recordingFiles,
            takes: takes,
            committer: RecordingTakeCommitter(
                fileStore: recordingFiles,
                takeRepository: takes,
                validator: AVAudioRecordingFileValidator()
            ),
            settings: settings,
            waveforms: waveformService,
            alignment: LocalRecordingAlignmentStore(rootDirectory: recordingFiles.rootURL),
            trash: .system
        )
    }

    private static func cleanupOrphanedTemporaryTakes(using fileStore: LocalRecordingFileStore) {
        do {
            _ = try fileStore.removeOrphanedTemporaryTakes()
        } catch {
            // Best-effort startup hygiene. Launch must succeed even if leftover temps remain;
            // later discard/commit paths still manage temporary files explicitly.
            _ = error.localizedDescription
        }
    }
}
