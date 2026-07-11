@preconcurrency import AVFoundation
import Foundation
@testable import Shadowing
import XCTest

final class M3ServiceTests: XCTestCase {
    func testMP3ValidatorRejectsUnsupportedAndMissingFiles() throws {
        let validator = MP3FileValidator()

        XCTAssertThrowsError(
            try validator.validate(URL(fileURLWithPath: "/tmp/example.wav"))
        ) { error in
            XCTAssertEqual(error as? AudioSourceError, .unsupportedFormat)
        }
        XCTAssertThrowsError(
            try validator.validate(URL(fileURLWithPath: "/tmp/missing-shadowing-test.mp3"))
        ) { error in
            XCTAssertEqual(error as? AudioSourceError, .fileMissing)
        }
    }

    func testMetadataLoaderReportsCorruptMP3AndObservesCancellation() async throws {
        let fixture = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString).mp3")
        try Data("not audio".utf8).write(to: fixture)
        defer {
            do {
                try FileManager.default.removeItem(at: fixture)
            } catch {
                XCTFail("Could not remove metadata fixture: \(error)")
            }
        }

        do {
            _ = try await AVAssetMetadataLoader().loadMetadata(from: fixture)
            XCTFail("Expected invalid MP3 metadata to fail")
        } catch let error as AudioSourceError {
            XCTAssertTrue([.corruptFile, .noAudioTrack].contains(error))
        }

        let task = Task {
            try await AVAssetMetadataLoader().loadMetadata(from: fixture)
        }
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("Expected metadata loading cancellation")
        } catch is CancellationError {
            // Expected.
        }
    }

    func testWaveformDownsamplerKeepsStrongestPeakInEachBucket() {
        let result = WaveformDownsampler.downsample(
            [0.1, 0.8, 0.2, 0.4, 0.9, 0.3],
            maximumCount: 3
        )

        XCTAssertEqual(result, [0.8, 0.4, 0.9])
    }

    func testBookmarkAccessStopsAfterOperationFailure() async throws {
        let access = StubBookmarkAccess(
            resolvedBookmark: ResolvedBookmark(
                url: URL(fileURLWithPath: "/tmp/source.mp3"),
                isStale: false
            )
        )
        let store = StubBookmarkStore(access: access)

        do {
            _ = try await store.withAccess(to: Data([1])) { _ -> Int in
                throw StubM3Error.forcedFailure
            }
            XCTFail("Expected bookmark operation to fail")
        } catch StubM3Error.forcedFailure {
            // Expected.
        }

        let stopCount = await access.stopCount
        XCTAssertEqual(stopCount, 1)
    }

    func testSecurityScopedBookmarkRoundTripsFileURL() async throws {
        let fixture = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString).mp3")
        try Data().write(to: fixture)
        defer {
            do {
                try FileManager.default.removeItem(at: fixture)
            } catch {
                XCTFail("Could not remove bookmark fixture: \(error)")
            }
        }

        let store = SecurityScopedBookmarkStore()
        let bookmark = try store.createBookmark(for: fixture)
        let resolvedPath = try await store.withAccess(to: bookmark) { resolved in
            resolved.url.standardizedFileURL.path
        }

        XCTAssertEqual(resolvedPath, fixture.standardizedFileURL.path)
    }

    func testSessionLoaderReleasesAccessWhenMetadataFails() async throws {
        let harness = makeLoaderHarness(metadata: FailingMetadataLoader())

        do {
            _ = try await harness.loader.prepareNewSource(
                at: URL(fileURLWithPath: "/tmp/source.mp3")
            )
            XCTFail("Expected preparation to fail")
        } catch let error as AudioSourceError {
            XCTAssertEqual(error, .corruptFile)
        }

        let stopCount = await harness.access.stopCount
        let recentProjects = try await harness.projects.recentProjects(limit: 10)
        let commands = await harness.audio.commands
        XCTAssertEqual(stopCount, 1)
        XCTAssertTrue(recentProjects.isEmpty)
        XCTAssertTrue(commands.isEmpty)
    }

    func testSessionLoaderCancellationReleasesAccessWithoutSaving() async throws {
        let harness = makeLoaderHarness(metadata: SlowMetadataLoader())
        let task = Task {
            try await harness.loader.prepareNewSource(
                at: URL(fileURLWithPath: "/tmp/source.mp3")
            )
        }

        for _ in 0 ..< 100 {
            if await harness.access.beginCount > 0 {
                break
            }
            await Task.yield()
        }
        let beginCount = await harness.access.beginCount
        XCTAssertEqual(beginCount, 1)
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("Expected session preparation cancellation")
        } catch is CancellationError {
            // Expected.
        }

        let stopCount = await harness.access.stopCount
        let recentProjects = try await harness.projects.recentProjects(limit: 10)
        XCTAssertEqual(stopCount, 1)
        XCTAssertTrue(recentProjects.isEmpty)
    }

    func testWaveformFailureDoesNotBlockPlayableSession() async throws {
        let harness = makeLoaderHarness(
            metadata: SuccessfulMetadataLoader(),
            waveform: FailingWaveformPreparer()
        )

        let prepared = try await harness.loader.prepareNewSource(
            at: URL(fileURLWithPath: "/tmp/source.mp3")
        )

        XCTAssertTrue(prepared.waveform.peaks.isEmpty)
        XCTAssertNotNil(prepared.waveform.warning)
        let commands = await harness.audio.commands
        XCTAssertEqual(commands, [.loadSource(URL(fileURLWithPath: "/tmp/source.mp3"))])

        await harness.loader.endSession()
        let stopCount = await harness.access.stopCount
        XCTAssertEqual(stopCount, 1)
    }

    private func makeLoaderHarness(
        metadata: any AudioAssetMetadataLoading,
        waveform: any WaveformPreparing = StubWaveformPreparer()
    ) -> LoaderHarness {
        let storage = InMemoryPersistence()
        let projects = InMemoryProjectRepository(storage: storage)
        let access = StubBookmarkAccess(
            resolvedBookmark: ResolvedBookmark(
                url: URL(fileURLWithPath: "/tmp/source.mp3"),
                isStale: false
            )
        )
        let audio = PracticeAudioClientSpy()
        let loader = AudioProjectSessionLoader(
            projects: projects,
            bookmarks: StubBookmarkStore(access: access),
            validator: AcceptingAudioFileValidator(),
            metadataLoader: metadata,
            waveformService: waveform,
            audioClient: audio,
            now: { Date(timeIntervalSince1970: 100) }
        )
        return LoaderHarness(
            loader: loader,
            projects: projects,
            access: access,
            audio: audio
        )
    }
}

private struct LoaderHarness {
    let loader: AudioProjectSessionLoader
    let projects: InMemoryProjectRepository
    let access: StubBookmarkAccess
    let audio: PracticeAudioClientSpy
}

private actor StubBookmarkAccess: BookmarkAccess {
    nonisolated let resolvedBookmark: ResolvedBookmark
    private(set) var beginCount = 0
    private(set) var stopCount = 0

    init(resolvedBookmark: ResolvedBookmark) {
        self.resolvedBookmark = resolvedBookmark
    }

    func markBegan() {
        beginCount += 1
    }

    func stop() {
        stopCount += 1
    }
}

private struct StubBookmarkStore: BookmarkStore {
    let access: StubBookmarkAccess

    func createBookmark(for _: URL) throws -> Data {
        Data([1])
    }

    func beginAccess(to _: Data) async throws -> any BookmarkAccess {
        await access.markBegan()
        return access
    }
}

private struct AcceptingAudioFileValidator: AudioFileValidating {
    func validate(_: URL) throws {}
}

private struct FailingMetadataLoader: AudioAssetMetadataLoading {
    func loadMetadata(from _: URL) async throws -> AudioAssetMetadata {
        throw AudioSourceError.corruptFile
    }
}

private struct SlowMetadataLoader: AudioAssetMetadataLoading {
    func loadMetadata(from _: URL) async throws -> AudioAssetMetadata {
        try await Task.sleep(for: .seconds(30))
        return AudioAssetMetadata(displayName: "source.mp3", duration: 30)
    }
}

private struct SuccessfulMetadataLoader: AudioAssetMetadataLoading {
    func loadMetadata(from _: URL) async throws -> AudioAssetMetadata {
        AudioAssetMetadata(displayName: "source.mp3", duration: 30)
    }
}

private struct StubWaveformPreparer: WaveformPreparing {
    func prepareWaveform(from _: URL) async throws -> WaveformPresentation {
        WaveformPresentation(peaks: [0.2, 0.6], warning: nil)
    }
}

private struct FailingWaveformPreparer: WaveformPreparing {
    func prepareWaveform(from _: URL) async throws -> WaveformPresentation {
        throw StubM3Error.forcedFailure
    }
}

private enum StubM3Error: Error {
    case forcedFailure
}
