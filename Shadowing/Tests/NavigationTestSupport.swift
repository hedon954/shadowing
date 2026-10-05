import Foundation
@testable import Shadowing
import XCTest

/// Fake app wiring for navigation and snapshot tests. Everything lives in memory or in a temp
/// folder; nothing touches the real Application Support data.
@MainActor
enum NavigationTestSupport {
    static func makeDependencies(
        testCase: XCTestCase,
        storage: InMemoryPersistence = InMemoryPersistence(),
        preparer: any PracticeSessionPreparing = RecordingSessionPreparer(),
        waveforms: (any WaveformPreparing)? = nil,
        recognizer: (any SpeechRecognizing)? = nil
    ) throws -> AppDependencies {
        let root = try M9TestSupport.makeTemporaryRoot()
        testCase.addTeardownBlock {
            try? FileManager.default.removeItem(at: root)
        }
        let takes = InMemoryTakeRepository(storage: storage)
        let fileStore = LocalRecordingFileStore(rootDirectory: root)
        return AppDependencies(
            fileChooser: M9FileChooser(),
            textFileChooser: NoTextFileChooser(),
            projects: InMemoryProjectRepository(storage: storage),
            takes: takes,
            settings: InMemorySettingsStore(storage: storage),
            audioClient: PracticeAudioClientSpy(),
            sessionPreparer: preparer,
            recording: RecordingDependencies(
                permissions: M9MicrophonePermissionServiceFake(status: .authorized),
                countdownClock: M9ImmediateCountdownClock(),
                fileStore: fileStore,
                takes: takes,
                committer: RecordingTakeCommitter(
                    fileStore: fileStore,
                    takeRepository: takes,
                    validator: AlwaysPlayableRecordingValidator()
                ),
                waveforms: waveforms,
                trash: .temporaryFolder()
            ),
            inputDevices: FixedInputDevices(),
            recordingsStorageURL: root,
            subtitles: SubtitleDependencies(
                store: LocalSubtitleFileStore(directory: root.appendingPathComponent("Subtitles", isDirectory: true)),
                audio: FakeSourceAudio(),
                recognizer: recognizer,
                fileChooser: StubSubtitleChooser()
            )
        )
    }
}

/// Records which projects were prepared; every preparation succeeds.
actor RecordingSessionPreparer: PracticeSessionPreparing {
    private(set) var preparedProjectIDs: [UUID] = []
    private(set) var endedSessions = 0

    func prepareNewSource(at url: URL) async throws -> PreparedPractice {
        let project = M9TestSupport.makeProject(name: url.lastPathComponent, openedAt: 300)
        preparedProjectIDs.append(project.id)
        return PreparedPractice(project: project, waveform: .unavailable)
    }

    func prepareExistingProject(id: UUID) async throws -> PreparedPractice {
        preparedProjectIDs.append(id)
        let project = AudioProject(
            id: id,
            sourceDisplayName: "Existing.mp3",
            sourceBookmark: Data([1]),
            duration: 30,
            playhead: 0,
            currentRegion: nil,
            selectedTakeID: nil,
            keptTakeID: nil,
            lastOpenedAt: Date(timeIntervalSince1970: 300)
        )
        return PreparedPractice(project: project, waveform: .unavailable)
    }

    func relocateProject(id: UUID, to _: URL) async throws -> PreparedPractice {
        try await prepareExistingProject(id: id)
    }

    func endSession() {
        endedSessions += 1
    }
}

struct NoTextFileChooser: TextFileChoosing {
    @MainActor
    func choosePlainText() async -> URL? {
        nil
    }
}

struct FixedInputDevices: AudioInputDeviceProviding {
    func availableInputDevices() async -> [AudioInputDevice] {
        [AudioInputDevice(id: "built-in", name: "MacBook Pro Microphone")]
    }

    func selectedInputDeviceID() async -> String? {
        "built-in"
    }

    func selectInputDevice(id _: String?) async throws {}

    func inputLevel() async -> Float {
        0.55
    }
}
