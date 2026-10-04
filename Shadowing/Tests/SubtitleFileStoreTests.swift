@testable import Shadowing
import XCTest

final class SubtitleFileStoreTests: XCTestCase {
    private var directory: URL!
    private var outside: URL!
    private let projectID = UUID()

    override func setUpWithError() throws {
        directory = try SubtitleTestSupport.makeDirectory()
        outside = try SubtitleTestSupport.makeDirectory()
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: directory)
        try FileManager.default.removeItem(at: outside)
    }

    func testImportCopiesTheFileAndLeavesTheOriginalAlone() async throws {
        let source = outside.appendingPathComponent("talk.srt")
        let body = "1\n00:00:01,000 --> 00:00:02,000\nHi\n"
        try body.write(to: source, atomically: true, encoding: .utf8)
        let before = try FileManager.default.attributesOfItem(atPath: source.path)[.modificationDate] as? Date
        let store = LocalSubtitleFileStore(directory: directory)

        let attached = try await store.importSubtitleFile(from: source, projectID: projectID)

        XCTAssertEqual(attached.displayName, "talk.srt")
        XCTAssertEqual(attached.format, .srt)
        XCTAssertEqual(attached.sha256, ContentHash.sha256(body))
        let copy = directory.appendingPathComponent("\(projectID.uuidString).source.srt")
        XCTAssertEqual(try String(contentsOf: copy, encoding: .utf8), body)
        XCTAssertEqual(try String(contentsOf: source, encoding: .utf8), body)
        let after = try FileManager.default.attributesOfItem(atPath: source.path)[.modificationDate] as? Date
        XCTAssertEqual(before, after)
        let text = try await store.attachedSubtitleText(projectID: projectID, format: .srt)
        XCTAssertEqual(text, body)
    }

    func testImportRejectsOtherFilesAndEmptySubtitles() async throws {
        let store = LocalSubtitleFileStore(directory: directory)
        let text = outside.appendingPathComponent("notes.txt")
        try "words".write(to: text, atomically: true, encoding: .utf8)
        await XCTAssertThrowsAsync { try await store.importSubtitleFile(from: text, projectID: projectID) }
        let empty = outside.appendingPathComponent("empty.vtt")
        try "WEBVTT\n".write(to: empty, atomically: true, encoding: .utf8)
        await XCTAssertThrowsAsync { try await store.importSubtitleFile(from: empty, projectID: projectID) }
        let contents = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        XCTAssertEqual(contents, [])
    }

    func testSubtitlesAndManifestUseTheProjectID() async throws {
        let store = LocalSubtitleFileStore(directory: directory)
        let empty = try await store.manifest(projectID: projectID)
        XCTAssertEqual(empty, SubtitleManifest())
        let cues = [SubtitleCue(start: 1, end: 2, text: "One.")]
        try await store.saveSubtitles(cues, projectID: projectID)
        var manifest = SubtitleManifest()
        manifest.selectedSource = .alignedText
        manifest.current = SubtitleProvenance(source: .alignedText, inputSHA256: "t", audioSHA256: "a")
        try await store.saveManifest(manifest, projectID: projectID)

        let srt = directory.appendingPathComponent("\(projectID.uuidString).srt")
        let json = directory.appendingPathComponent("\(projectID.uuidString).json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: srt.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: json.path))
        let loadedCues = try await store.subtitles(projectID: projectID)
        XCTAssertEqual(loadedCues, cues)
        let loadedManifest = try await store.manifest(projectID: projectID)
        XCTAssertEqual(loadedManifest, manifest)
    }

    func testDamagedWordCacheCountsAsMissing() async throws {
        let store = LocalSubtitleFileStore(directory: directory)
        let speech = RecognizedSpeech(audioSHA256: "a", words: [TranscribedWord(text: "Hi", start: 0, end: 1)])
        try await store.saveRecognizedSpeech(speech, projectID: projectID)
        let loaded = try await store.recognizedSpeech(projectID: projectID)
        XCTAssertEqual(loaded, speech)
        let cache = directory.appendingPathComponent("\(projectID.uuidString).words.json")
        try Data("{".utf8).write(to: cache)
        let damaged = try await store.recognizedSpeech(projectID: projectID)
        XCTAssertNil(damaged)
    }
}

func XCTAssertThrowsAsync(
    file: StaticString = #filePath,
    line: UInt = #line,
    _ expression: () async throws -> some Any
) async {
    do {
        _ = try await expression()
        XCTFail("Expected an error", file: file, line: line)
    } catch {
        // Expected.
    }
}
