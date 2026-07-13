import Foundation
@testable import Shadowing
import XCTest

@MainActor
final class ScriptViewModelTests: XCTestCase {
    func testAttachScriptCopiesTextAndPersistsDisplayName() async throws {
        let fixture = try await makeFixture(testCase: self)
        let source = fixture.root.appendingPathComponent("speech.txt", isDirectory: false)
        let body = "Practice this sentence."
        try body.write(to: source, atomically: true, encoding: .utf8)
        fixture.chooser.url = source

        fixture.viewModel.attachScript()
        await M7TestSupport.waitUntil {
            fixture.viewModel.scriptText == body
        }

        XCTAssertEqual(fixture.viewModel.scriptText, body)
        XCTAssertEqual(fixture.viewModel.project.scriptDisplayName, "speech.txt")
        await M7TestSupport.waitUntil {
            let saved = try? await fixture.projects.project(id: fixture.project.id)
            return saved?.scriptDisplayName == "speech.txt"
        }
        XCTAssertEqual(
            try fixture.fileStore.loadScriptText(projectID: fixture.project.id),
            body
        )
    }

    func testHydrateLoadsAttachedScript() async throws {
        let fixture = try await makeFixture(testCase: self)
        let source = fixture.root.appendingPathComponent("notes.txt", isDirectory: false)
        try "Hydrated script.".write(to: source, atomically: true, encoding: .utf8)
        try fixture.fileStore.commitScript(from: source, projectID: fixture.project.id)
        fixture.viewModel.project.scriptDisplayName = "notes.txt"
        try await fixture.projects.save(fixture.viewModel.project)

        await fixture.viewModel.hydrateRestoredSession()

        XCTAssertEqual(fixture.viewModel.scriptText, "Hydrated script.")
        XCTAssertEqual(fixture.viewModel.project.scriptDisplayName, "notes.txt")
    }

    private func makeFixture(testCase: XCTestCase) async throws -> ScriptFixture {
        let storage = InMemoryPersistence()
        let projects = InMemoryProjectRepository(storage: storage)
        let takes = InMemoryTakeRepository(storage: storage)
        let project = AudioProject(
            id: UUID(),
            sourceDisplayName: "Speech.mp3",
            sourceBookmark: Data([1]),
            duration: 30,
            playhead: 0,
            currentRegion: nil,
            selectedTakeID: nil,
            keptTakeID: nil,
            lastOpenedAt: Date(timeIntervalSince1970: 100)
        )
        try await projects.save(project)

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ShadowingScriptTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        testCase.addTeardownBlock {
            try? FileManager.default.removeItem(at: root)
        }

        let fileStore = LocalRecordingFileStore(rootDirectory: root)
        let chooser = StubTextFileChooser()
        let viewModel = PracticeViewModel(
            prepared: PreparedPractice(
                project: project,
                waveform: WaveformPresentation(peaks: [0.2, 0.4], warning: nil)
            ),
            audioClient: PracticeAudioClientSpy(),
            projects: projects,
            sessionPreparer: M7SessionPreparer(),
            recordingDependencies: RecordingDependencies(
                permissions: M7MicrophonePermissionServiceFake(status: .authorized),
                countdownClock: M7ImmediateCountdownClock(),
                fileStore: fileStore,
                takes: takes,
                committer: RecordingTakeCommitter(
                    fileStore: fileStore,
                    takeRepository: takes,
                    validator: AlwaysPlayableRecordingValidator()
                ),
                countdownSeconds: 0
            ),
            textFileChooser: chooser
        )
        return ScriptFixture(
            viewModel: viewModel,
            projects: projects,
            fileStore: fileStore,
            chooser: chooser,
            project: project,
            root: root
        )
    }
}

@MainActor
private struct ScriptFixture {
    let viewModel: PracticeViewModel
    let projects: InMemoryProjectRepository
    let fileStore: LocalRecordingFileStore
    let chooser: StubTextFileChooser
    let project: AudioProject
    let root: URL
}

@MainActor
private final class StubTextFileChooser: TextFileChoosing {
    var url: URL?

    func choosePlainText() async -> URL? {
        url
    }
}
