import Foundation
@testable import Shadowing
import XCTest

/// Opening or relocating a project rebuilds it from fresh audio metadata. Every persisted field
/// that is not derived from the audio file must survive that rebuild and the following save.
final class SessionLoaderProjectFieldsTests: XCTestCase {
    func testOpeningProjectKeepsScriptNameAndStoredFields() async throws {
        let fixture = try await makeFixture()

        let prepared = try await fixture.loader.prepareExistingProject(id: fixture.project.id)
        let saved = try await fixture.projects.project(id: fixture.project.id)

        assertKeepsStoredFields(prepared.project, of: fixture.project)
        XCTAssertEqual(saved, prepared.project)
    }

    func testRelocatingProjectKeepsScriptName() async throws {
        let fixture = try await makeFixture()

        let prepared = try await fixture.loader.relocateProject(
            id: fixture.project.id,
            to: URL(fileURLWithPath: "/tmp/relocated-source.mp3")
        )
        let saved = try await fixture.projects.project(id: fixture.project.id)

        XCTAssertEqual(prepared.project.scriptDisplayName, "speech.txt")
        XCTAssertEqual(saved?.scriptDisplayName, "speech.txt")
    }

    private func assertKeepsStoredFields(
        _ reopened: AudioProject,
        of original: AudioProject,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(reopened.id, original.id, file: file, line: line)
        XCTAssertEqual(reopened.scriptDisplayName, original.scriptDisplayName, file: file, line: line)
        XCTAssertEqual(reopened.sourceBookmark, original.sourceBookmark, file: file, line: line)
        XCTAssertEqual(reopened.playhead, original.playhead, file: file, line: line)
        XCTAssertEqual(reopened.currentRegion, original.currentRegion, file: file, line: line)
        XCTAssertEqual(reopened.selectedTakeID, original.selectedTakeID, file: file, line: line)
        XCTAssertEqual(reopened.keptTakeID, original.keptTakeID, file: file, line: line)
        XCTAssertEqual(reopened.playbackRate, original.playbackRate, file: file, line: line)
    }

    private func makeFixture() async throws -> Fixture {
        let storage = InMemoryPersistence()
        let projects = InMemoryProjectRepository(storage: storage)
        let project = try AudioProject(
            id: UUID(),
            sourceDisplayName: "source.mp3",
            sourceBookmark: Data([1]),
            duration: 40,
            playhead: 5,
            currentRegion: PracticeRegion(start: 2, end: 7, sourceDuration: 40),
            selectedTakeID: UUID(),
            keptTakeID: UUID(),
            lastOpenedAt: Date(timeIntervalSince1970: 10),
            playbackRate: 1.25,
            scriptDisplayName: "speech.txt"
        )
        try await projects.save(project)
        let loader = AudioProjectSessionLoader(
            projects: projects,
            bookmarks: M7BookmarkStore(
                access: M7BookmarkAccess(
                    resolvedBookmark: ResolvedBookmark(
                        url: URL(fileURLWithPath: "/tmp/source.mp3"),
                        isStale: false
                    )
                )
            ),
            validator: M7AcceptingValidator(),
            metadataLoader: M7MetadataLoader(
                metadata: AudioAssetMetadata(displayName: "source.mp3", duration: 40)
            ),
            waveformService: M7WaveformPreparer(),
            audioClient: PracticeAudioClientSpy(),
            now: { Date(timeIntervalSince1970: 99) }
        )
        return Fixture(projects: projects, project: project, loader: loader)
    }
}

private struct Fixture {
    let projects: InMemoryProjectRepository
    let project: AudioProject
    let loader: AudioProjectSessionLoader
}
