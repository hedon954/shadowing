import Foundation
@testable import Shadowing
import Synchronization
import XCTest

/// Bookmarks saved by an older, differently signed build cannot be resolved with
/// `.withSecurityScope`. These tests cover the plain-resolve fallback with temporary fixtures.
final class BookmarkFallbackTests: XCTestCase {
    private var fixtureDirectory: URL!

    override func setUpWithError() throws {
        fixtureDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("BookmarkFallbackTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: fixtureDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: fixtureDirectory)
    }

    func testScopedResolveFailureFallsBackToPlainResolveAndMarksStale() async throws {
        let source = try makeSource()
        let legacy = try makeLegacyScopedBookmark(for: source)
        let log = ResolveLog()
        let store = SecurityScopedBookmarkStore(
            createsSecurityScopedBookmarks: false,
            resolver: log.resolver(rejectingScopedResolveOf: legacy)
        )

        let resolved = try await store.withAccess(to: legacy) { $0 }

        XCTAssertEqual(resolved.url.standardizedFileURL.path, source.standardizedFileURL.path)
        XCTAssertTrue(resolved.isStale, "A fallback-resolved bookmark must be re-saved")
        XCTAssertEqual(log.calls.map(\.scoped), [true, false])
    }

    func testBothResolvesFailingThrowsOriginalErrorAndOffersRelocate() async throws {
        let store = SecurityScopedBookmarkStore(
            createsSecurityScopedBookmarks: false,
            resolver: { _, options in
                throw options.contains(.withSecurityScope) ? FixtureError.scoped : FixtureError.plain
            }
        )

        do {
            _ = try await store.beginAccess(to: Data([1, 2, 3]))
            XCTFail("Expected both resolves to fail")
        } catch let error as BookmarkStoreError {
            XCTAssertEqual(error, .resolutionFailed(reason: FixtureError.scoped.localizedDescription))
        }

        let harness = makeLoader(store: store)
        let project = makeProject(bookmark: Data([1, 2, 3]))
        await harness.storage.save(project: project)
        let failure = await Self.openThroughLibrary(project, harness: harness)
        XCTAssertEqual(failure?.action, .relocate(project.id))
    }

    func testFallbackReSavesBookmarkAndNextOpenUsesIt() async throws {
        let source = try makeSource()
        let legacy = try makeLegacyScopedBookmark(for: source)
        let log = ResolveLog()
        let store = SecurityScopedBookmarkStore(
            createsSecurityScopedBookmarks: false,
            resolver: log.resolver(rejectingScopedResolveOf: legacy)
        )
        let harness = makeLoader(store: store)
        let project = makeProject(bookmark: legacy)
        await harness.storage.save(project: project)

        _ = try await harness.loader.prepareExistingProject(id: project.id)
        await harness.loader.endSession()
        let saved = await harness.storage.project(id: project.id)
        let resaved = try XCTUnwrap(saved?.sourceBookmark)
        XCTAssertNotEqual(resaved, legacy)
        XCTAssertEqual(resaved, try store.createBookmark(for: source))

        log.reset()
        let reopened = try await harness.loader.prepareExistingProject(id: project.id)
        await harness.loader.endSession()

        XCTAssertFalse(log.calls.isEmpty)
        XCTAssertTrue(log.calls.allSatisfy { $0.data == resaved })
        XCTAssertEqual(reopened.project.sourceBookmark, resaved)
    }

    func testPlainBookmarkIsReadableWithoutSecurityScope() async throws {
        let source = try makeSource()
        let store = SecurityScopedBookmarkStore(createsSecurityScopedBookmarks: false)

        let bookmark = try store.createBookmark(for: source)
        let path = try await store.withAccess(to: bookmark) { $0.url.standardizedFileURL.path }

        XCTAssertEqual(path, source.standardizedFileURL.path)
    }

    func testUnreadableFileIsReportedAsAccessDenied() async throws {
        let source = try makeSource()
        let store = SecurityScopedBookmarkStore(
            createsSecurityScopedBookmarks: false,
            isReadable: { _ in false }
        )
        let bookmark = try store.createBookmark(for: source)

        do {
            _ = try await store.beginAccess(to: bookmark)
            XCTFail("Expected an unreadable file to be denied")
        } catch let BookmarkStoreError.accessDenied(path) {
            XCTAssertEqual(
                URL(fileURLWithPath: path).resolvingSymlinksInPath().path,
                source.resolvingSymlinksInPath().path
            )
        }
    }

    // MARK: - Fixtures

    private func makeSource() throws -> URL {
        let url = fixtureDirectory.appendingPathComponent("source.mp3")
        try Data("fixture".utf8).write(to: url)
        return url
    }

    /// The format older builds saved: security-scoped and read-only.
    private func makeLegacyScopedBookmark(for url: URL) throws -> Data {
        try url.bookmarkData(
            options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
    }

    private func makeProject(bookmark: Data) -> AudioProject {
        AudioProject(
            id: UUID(),
            sourceDisplayName: "source.mp3",
            sourceBookmark: bookmark,
            duration: 40,
            playhead: 0,
            currentRegion: nil,
            selectedTakeID: nil,
            keptTakeID: nil,
            lastOpenedAt: Date(timeIntervalSince1970: 10)
        )
    }

    private func makeLoader(store: SecurityScopedBookmarkStore) -> LoaderFixture {
        let storage = InMemoryPersistence()
        let loader = AudioProjectSessionLoader(
            projects: InMemoryProjectRepository(storage: storage),
            bookmarks: store,
            validator: M7AcceptingValidator(),
            metadataLoader: M7MetadataLoader(
                metadata: AudioAssetMetadata(displayName: "source.mp3", duration: 40)
            ),
            waveformService: M7WaveformPreparer(),
            audioClient: PracticeAudioClientSpy(),
            now: { Date(timeIntervalSince1970: 99) }
        )
        return LoaderFixture(storage: storage, loader: loader)
    }

    @MainActor
    private static func openThroughLibrary(_ project: AudioProject, harness: LoaderFixture) async -> FileLoadFailure? {
        let viewModel = FilesViewModel(
            chooser: M7Chooser(url: nil),
            sessionPreparer: harness.loader,
            projects: InMemoryProjectRepository(storage: harness.storage),
            takes: InMemoryTakeRepository(storage: harness.storage)
        ) { _ in }
        viewModel.openLibraryItem(LibraryProjectItem(project: project, takeCount: 0, lastRecordedAt: nil))
        for _ in 0 ..< 500 where viewModel.state.failure == nil {
            await Task.yield()
        }
        return viewModel.state.failure
    }
}

private struct LoaderFixture {
    let storage: InMemoryPersistence
    let loader: AudioProjectSessionLoader
}

private enum FixtureError: Error, LocalizedError {
    case scoped
    case plain

    var errorDescription: String? {
        switch self {
        case .scoped: "scoped resolve failed"
        case .plain: "plain resolve failed"
        }
    }
}

/// Records resolve attempts and simulates a bookmark written by a differently signed build.
private final class ResolveLog: Sendable {
    struct Call: Sendable {
        let data: Data
        let scoped: Bool
    }

    private let storage = Mutex<[Call]>([])

    var calls: [Call] {
        storage.withLock { $0 }
    }

    func reset() {
        storage.withLock { $0.removeAll() }
    }

    func resolver(rejectingScopedResolveOf rejected: Data) -> SecurityScopedBookmarkStore.Resolver {
        { [self] data, options in
            let scoped = options.contains(.withSecurityScope)
            storage.withLock { $0.append(Call(data: data, scoped: scoped)) }
            if scoped, data == rejected {
                throw CocoaError(.fileReadCorruptFile)
            }
            return try SecurityScopedBookmarkStore.systemResolve(data, options: options)
        }
    }
}
