import Foundation

@MainActor
final class AppDependencies {
    let fileChooser: any AudioFileChoosing
    let projects: any ProjectRepository
    let audioClient: any PracticeAudioClient
    let sessionPreparer: any PracticeSessionPreparing
    let recording: RecordingDependencies

    init(
        fileChooser: any AudioFileChoosing,
        projects: any ProjectRepository,
        audioClient: any PracticeAudioClient,
        sessionPreparer: any PracticeSessionPreparing,
        recording: RecordingDependencies
    ) {
        self.fileChooser = fileChooser
        self.projects = projects
        self.audioClient = audioClient
        self.sessionPreparer = sessionPreparer
        self.recording = recording
    }

    static func live(fileManager: FileManager = .default) throws -> AppDependencies {
        let applicationSupport = try fileManager.url(
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

        let database = try AppDatabase.open(
            at: applicationSupport.appendingPathComponent("Shadowing.sqlite", isDirectory: false)
        )
        let projects = GRDBProjectRepository(database: database)
        let takes = GRDBTakeRepository(database: database)
        let recordingFiles = LocalRecordingFileStore(
            rootDirectory: applicationSupport.appendingPathComponent(
                "Recordings",
                isDirectory: true
            )
        )
        let audioClient = PracticeAudioEngine()
        let waveformCache = WaveformFileCache(
            directory: applicationSupport.appendingPathComponent("Waveforms", isDirectory: true)
        )
        let sessionPreparer = AudioProjectSessionLoader(
            projects: projects,
            bookmarks: SecurityScopedBookmarkStore(),
            validator: MP3FileValidator(),
            metadataLoader: AVAssetMetadataLoader(),
            waveformService: CachedWaveformService(cache: waveformCache),
            audioClient: audioClient
        )

        return AppDependencies(
            fileChooser: SystemAudioFileChooser(),
            projects: projects,
            audioClient: audioClient,
            sessionPreparer: sessionPreparer,
            recording: RecordingDependencies(
                permissions: SystemMicrophonePermissionService(),
                countdownClock: ContinuousRecordingCountdownClock(),
                fileStore: recordingFiles,
                takes: takes,
                committer: RecordingTakeCommitter(
                    fileStore: recordingFiles,
                    takeRepository: takes,
                    validator: AVAudioRecordingFileValidator()
                )
            )
        )
    }
}
