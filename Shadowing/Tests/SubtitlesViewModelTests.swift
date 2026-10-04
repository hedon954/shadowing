@testable import Shadowing
import XCTest

@MainActor
final class SubtitlesViewModelTests: XCTestCase {
    private let script = SubtitleScript(
        text: "Every morning I walk to the harbor. The boats are still asleep.",
        displayName: "harbor.txt"
    )
    private var spoken: [TranscribedWord] {
        SubtitleTestSupport.words("Every morning I walk to the harbor. The boats are still asleep.", start: 3)
    }

    private let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("ShadowingSubtitles-\(UUID().uuidString)", isDirectory: true)

    override func setUpWithError() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: directory)
    }

    private func makeModel(
        project: AudioProject = M9TestSupport.makeProject(name: "Harbor.mp3", openedAt: 1),
        recognizer: (any SpeechRecognizing)?
    ) -> SubtitlesViewModel {
        SubtitlesViewModel(
            project: project,
            dependencies: SubtitleDependencies(
                store: LocalSubtitleFileStore(directory: directory),
                audio: FakeSourceAudio(),
                recognizer: recognizer,
                fileChooser: StubSubtitleChooser()
            )
        )
    }

    func testTextAlignsAutomaticallyAndIsSavedAsTheProjectSRT() async {
        let recognizer = FakeSpeechRecognizer(words: spoken)
        let project = M9TestSupport.makeProject(name: "Harbor.mp3", openedAt: 1)
        let model = makeModel(project: project, recognizer: recognizer)

        model.load(script: script)
        await model.loadTask?.value

        guard case let .timed(transcript) = model.display else {
            return XCTFail("Expected timed subtitles, got \(model.display)")
        }
        XCTAssertEqual(
            transcript.cues.map(\.text),
            ["Every morning I walk to the harbor.", "The boats are still asleep."]
        )
        XCTAssertEqual(transcript.cues[1].start, 3 + 7 * 0.5, accuracy: 0.001)
        XCTAssertEqual(model.activeSource, .alignedText)
        XCTAssertEqual(model.activeSourceName, "harbor.txt")
        let srt = directory.appendingPathComponent("\(project.id.uuidString).srt")
        XCTAssertTrue(FileManager.default.fileExists(atPath: srt.path))
        let calls = await recognizer.calls.count
        XCTAssertEqual(calls, 1)

        // Reopening reuses the saved subtitles without recognizing again.
        let reopened = makeModel(project: project, recognizer: recognizer)
        reopened.load(script: script)
        await reopened.loadTask?.value
        XCTAssertEqual(reopened.display, model.display)
        let callsAfterReopen = await recognizer.calls.count
        XCTAssertEqual(callsAfterReopen, 1)
    }

    func testPoorMatchShowsPlainTextAndIsNotRetried() async {
        let unrelated = SubtitleTestSupport.words("completely different words were spoken here")
        let recognizer = FakeSpeechRecognizer(words: unrelated)
        let project = M9TestSupport.makeProject(name: "Harbor.mp3", openedAt: 1)
        let model = makeModel(project: project, recognizer: recognizer)

        model.load(script: script)
        await model.loadTask?.value

        XCTAssertEqual(model.display, .plainText(script.text, notice: .alignmentFailed))
        let reopened = makeModel(project: project, recognizer: recognizer)
        reopened.load(script: script)
        await reopened.loadTask?.value
        XCTAssertEqual(reopened.display, .plainText(script.text, notice: .alignmentFailed))
        let calls = await recognizer.calls.count
        XCTAssertEqual(calls, 1)
    }

    func testRecognitionFailureShowsPlainTextWithTheReason() async {
        let model = makeModel(recognizer: FakeSpeechRecognizer(failure: .unavailable))
        model.load(script: script)
        await model.loadTask?.value
        XCTAssertEqual(model.display, .plainText(script.text, notice: .alignmentFailed))
        XCTAssertEqual(model.failureDetail, SpeechRecognitionError.unavailable.localizedDescription)
    }

    func testWithoutSpeechRecognitionTextStaysPlain() async {
        // macOS 15 has no SpeechAnalyzer: the text is shown untimed and without a warning.
        let model = makeModel(recognizer: nil)
        model.load(script: script)
        await model.loadTask?.value
        XCTAssertEqual(model.display, .plainText(script.text, notice: nil))
    }

    func testNoSourcesShowsTheEmptyState() async {
        let model = makeModel(recognizer: FakeSpeechRecognizer())
        model.load(script: nil)
        await model.loadTask?.value
        XCTAssertEqual(model.display, .empty)
        XCTAssertNil(model.activeSourceName)
    }

    func testAttachedSubtitleFileWinsOverTextAndCanBeSwitched() async throws {
        let recognizer = FakeSpeechRecognizer(words: spoken)
        let model = makeModel(recognizer: recognizer)
        let file = directory.appendingPathComponent("harbor.vtt")
        try "WEBVTT\n\n00:01.000 --> 00:02.000\nFrom the file\n".write(to: file, atomically: true, encoding: .utf8)
        model.load(script: script)
        await model.loadTask?.value

        model.importSubtitleFile(from: file)
        await model.loadTask?.value

        XCTAssertEqual(model.activeSource, .subtitleFile)
        XCTAssertEqual(model.sources.map(\.kind), [.subtitleFile, .alignedText, .fromAudio])
        let fileCues = [SubtitleCue(start: 1, end: 2, text: "From the file")]
        XCTAssertEqual(model.display, .timed(SubtitleTranscript(cues: fileCues)))

        model.select(.alignedText)
        await model.loadTask?.value
        XCTAssertEqual(model.activeSource, .alignedText)
        guard case .timed = model.display else {
            return XCTFail("Expected aligned text")
        }
        // The recognized words are cached: switching back and forth recognizes once.
        model.select(.subtitleFile)
        await model.loadTask?.value
        model.select(.alignedText)
        await model.loadTask?.value
        let calls = await recognizer.calls.count
        XCTAssertEqual(calls, 1)
    }
}
