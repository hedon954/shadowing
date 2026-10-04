@testable import Shadowing
import XCTest

@MainActor
final class SubtitleGenerationTests: XCTestCase {
    private let speech = "Good morning everyone. Today we talk about rivers."
    private let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("ShadowingSubtitles-\(UUID().uuidString)", isDirectory: true)
    private lazy var project = M9TestSupport.makeProject(name: "Rivers.mp3", openedAt: 1)

    override func setUpWithError() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: directory)
    }

    private func makeModel(
        recognizer: (any SpeechRecognizing)?,
        exportURL: URL? = nil
    ) -> SubtitlesViewModel {
        SubtitlesViewModel(
            project: project,
            dependencies: SubtitleDependencies(
                store: LocalSubtitleFileStore(directory: directory),
                audio: FakeSourceAudio(),
                recognizer: recognizer,
                fileChooser: StubSubtitleChooser(exportURL: exportURL)
            )
        )
    }

    private var srtURL: URL {
        directory.appendingPathComponent("\(project.id.uuidString).srt")
    }

    func testGenerationRunsOnlyWhenAskedAndIsSavedAsTheProjectSRT() async throws {
        let recognizer = FakeSpeechRecognizer(words: SubtitleTestSupport.words(speech, start: 1))
        let model = makeModel(recognizer: recognizer)
        model.load(script: nil)
        await model.loadTask?.value

        XCTAssertEqual(model.display, .empty)
        XCTAssertEqual(model.sources, [SubtitleSourceOption(kind: .fromAudio, name: "From audio", isReady: false)])
        XCTAssertNil(model.activeSource)
        var calls = await recognizer.calls.count
        XCTAssertEqual(calls, 0, "Recognition must not start by itself")
        XCTAssertFalse(FileManager.default.fileExists(atPath: srtURL.path))

        model.generateFromAudio()
        await model.loadTask?.value

        guard case let .timed(transcript) = model.display else {
            return XCTFail("Expected generated subtitles, got \(model.display)")
        }
        XCTAssertEqual(transcript.cues.map(\.text), ["Good morning everyone.", "Today we talk about rivers."])
        XCTAssertEqual(model.activeSource, .fromAudio)
        XCTAssertEqual(model.activeSourceName, "From audio")
        XCTAssertFalse(model.isGenerating)
        XCTAssertNil(model.generationError)
        let saved = try SubtitleParser.parse(String(contentsOf: srtURL, encoding: .utf8), format: .srt)
        XCTAssertEqual(saved, transcript.cues)
        calls = await recognizer.calls.count
        XCTAssertEqual(calls, 1)

        let reopened = makeModel(recognizer: recognizer)
        reopened.load(script: nil)
        await reopened.loadTask?.value
        XCTAssertEqual(reopened.display, model.display)
        calls = await recognizer.calls.count
        XCTAssertEqual(calls, 1)
    }

    func testFailureKeepsThePreviousContentAndExplainsWhy() async {
        let model = makeModel(recognizer: FakeSpeechRecognizer(failure: .unavailable))
        model.load(script: nil)
        await model.loadTask?.value

        model.generateFromAudio()
        await model.loadTask?.value

        XCTAssertEqual(model.display, .empty)
        XCTAssertEqual(model.generationError, SpeechRecognitionError.unavailable.localizedDescription)
        XCTAssertFalse(model.isGenerating)
        XCTAssertFalse(FileManager.default.fileExists(atPath: srtURL.path))
    }

    func testSilenceCountsAsAFailure() async {
        let model = makeModel(recognizer: FakeSpeechRecognizer(words: []))
        model.load(script: SubtitleScript(text: "Some text.", displayName: "notes.txt"))
        await model.loadTask?.value

        model.generateFromAudio()
        await model.loadTask?.value

        XCTAssertEqual(model.generationError, SpeechRecognitionError.noSpeech.localizedDescription)
        XCTAssertEqual(model.activeSource, .alignedText)
    }

    func testPickingFromAudioBeforeGeneratingStartsGeneration() async {
        let model = makeModel(recognizer: FakeSpeechRecognizer(words: SubtitleTestSupport.words(speech)))
        model.load(script: nil)
        await model.loadTask?.value

        model.select(.fromAudio)
        await model.loadTask?.value

        XCTAssertEqual(model.activeSource, .fromAudio)
        XCTAssertEqual(model.sources.map(\.isReady), [true])
    }

    func testGeneratedSubtitlesComeBackAfterSwitchingSourcesWithoutRecognizingAgain() async {
        let recognizer = FakeSpeechRecognizer(words: SubtitleTestSupport.words(speech))
        let model = makeModel(recognizer: recognizer)
        model.load(script: SubtitleScript(text: speech, displayName: "rivers.txt"))
        await model.loadTask?.value
        XCTAssertEqual(model.activeSource, .alignedText)

        model.generateFromAudio()
        await model.loadTask?.value
        let generated = model.display
        model.select(.alignedText)
        await model.loadTask?.value
        XCTAssertEqual(model.activeSource, .alignedText)
        model.select(.fromAudio)
        await model.loadTask?.value

        XCTAssertEqual(model.activeSource, .fromAudio)
        XCTAssertEqual(model.display, generated)
        let calls = await recognizer.calls.count
        XCTAssertEqual(calls, 1, "Words are recognized once per audio file")
    }

    func testRecognizedTextAppearsWhileGenerating() {
        let model = makeModel(recognizer: FakeSpeechRecognizer())
        model.receive(
            .recognized(words: SubtitleTestSupport.words("Good morning"), progress: 0.42),
            phase: .recognizing,
            text: "Good morning"
        )
        XCTAssertEqual(
            model.display,
            .working(SubtitleWork(phase: .recognizing, fraction: 0.42), text: "Good morning")
        )
        model.receive(.recognized(words: [], progress: 0.425), phase: .recognizing, text: "Good morning everyone.")
        XCTAssertEqual(
            model.display,
            .working(SubtitleWork(phase: .recognizing, fraction: 0.425), text: "Good morning everyone.")
        )
    }

    func testExportWritesTheShownSubtitlesToTheChosenFile() async throws {
        let destination = directory.appendingPathComponent("export/Rivers.srt")
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let model = makeModel(
            recognizer: FakeSpeechRecognizer(words: SubtitleTestSupport.words(speech)),
            exportURL: destination
        )
        model.load(script: nil)
        await model.loadTask?.value
        XCTAssertNil(model.exportableCues)
        model.generateFromAudio()
        await model.loadTask?.value
        let cues = try XCTUnwrap(model.exportableCues)

        model.exportSRT()
        await model.exportTask?.value

        let exported = try String(contentsOf: destination, encoding: .utf8)
        XCTAssertEqual(exported, SubtitleSRTWriter.srt(from: cues))
    }

    func testWithoutOnDeviceRecognitionGenerationIsUnavailable() async {
        let model = makeModel(recognizer: nil)
        model.load(script: nil)
        await model.loadTask?.value
        XCTAssertFalse(model.canGenerate)
        XCTAssertTrue(model.sources.isEmpty)
        model.generateFromAudio()
        await model.loadTask?.value
        XCTAssertEqual(model.display, .empty)
    }
}
