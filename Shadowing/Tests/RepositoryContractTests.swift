import GRDB
@testable import Shadowing
import XCTest

struct RepositoryContractContext {
    let projects: any ProjectRepository
    let takes: any TakeRepository
    let settings: any SettingsStore
}

struct ProjectRepositoryContract {
    let repository: any ProjectRepository

    func assertSaveUpdateAndLookup() async throws {
        var project = makeProject(lastOpenedAt: Date(timeIntervalSince1970: 100))
        try await repository.save(project)
        let initiallyLoaded = try await repository.project(id: project.id)
        XCTAssertEqual(initiallyLoaded, project)

        let region = try PracticeRegion(start: 1, end: 4, sourceDuration: project.duration)
        project.playhead = 2
        project.currentRegion = region
        project.sourceDisplayName = "renamed.mp3"
        try await repository.save(project)

        let updated = try await repository.project(id: project.id)
        XCTAssertEqual(updated, project)
    }

    func assertRecentOrderingAndLimit() async throws {
        let older = makeProject(lastOpenedAt: Date(timeIntervalSince1970: 100))
        let newer = makeProject(lastOpenedAt: Date(timeIntervalSince1970: 200))
        try await repository.save(older)
        try await repository.save(newer)

        let limited = try await repository.recentProjects(limit: 1)
        let empty = try await repository.recentProjects(limit: 0)
        XCTAssertEqual(limited, [newer])
        XCTAssertEqual(empty, [])
    }

    func assertDelete() async throws {
        let project = makeProject(lastOpenedAt: Date(timeIntervalSince1970: 100))
        try await repository.save(project)
        try await repository.deleteProject(id: project.id)

        let deleted = try await repository.project(id: project.id)
        XCTAssertNil(deleted)
    }

    private func makeProject(lastOpenedAt: Date) -> AudioProject {
        AudioProject(
            id: UUID(),
            sourceDisplayName: "source.mp3",
            sourceBookmark: Data([1, 2, 3]),
            duration: 90,
            playhead: 0,
            currentRegion: nil,
            selectedTakeID: nil,
            keptTakeID: nil,
            lastOpenedAt: lastOpenedAt
        )
    }
}

struct TakeRepositoryContract {
    let projects: any ProjectRepository
    let takes: any TakeRepository

    func assertSaveUpdateOrderingAndDelete() async throws {
        let project = makeProject()
        try await projects.save(project)
        let region = try PracticeRegion(start: 1, end: 4, sourceDuration: project.duration)
        let second = try makeTake(
            projectID: project.id,
            region: region,
            sequence: 2,
            duration: 3
        )
        var first = try makeTake(
            projectID: project.id,
            region: region,
            sequence: 1,
            duration: 3
        )

        try await takes.save(second)
        try await takes.save(first)
        let initiallyLoaded = try await takes.takes(projectID: project.id)
        XCTAssertEqual(initiallyLoaded, [first, second])

        first = try Take(
            id: first.id,
            projectID: first.projectID,
            region: first.region,
            sequence: first.sequence,
            relativeAudioPath: first.relativeAudioPath,
            duration: 2.5,
            createdAt: first.createdAt
        )
        try await takes.save(first)
        let updated = try await takes.takes(projectID: project.id)
        XCTAssertEqual(updated, [first, second])

        try await takes.deleteTake(id: first.id)
        let remaining = try await takes.takes(projectID: project.id)
        XCTAssertEqual(remaining, [second])
    }

    func assertProjectDeleteCascadesTakes() async throws {
        let project = makeProject()
        try await projects.save(project)
        let region = try PracticeRegion(start: 0, end: 2, sourceDuration: project.duration)
        let take = try makeTake(
            projectID: project.id,
            region: region,
            sequence: 1,
            duration: 2
        )
        try await takes.save(take)

        try await projects.deleteProject(id: project.id)

        let remaining = try await takes.takes(projectID: project.id)
        XCTAssertEqual(remaining, [])
    }

    private func makeProject() -> AudioProject {
        AudioProject(
            id: UUID(),
            sourceDisplayName: "source.mp3",
            sourceBookmark: Data([4, 5, 6]),
            duration: 90,
            playhead: 0,
            currentRegion: nil,
            selectedTakeID: nil,
            keptTakeID: nil,
            lastOpenedAt: Date(timeIntervalSince1970: 100)
        )
    }

    private func makeTake(
        projectID: UUID,
        region: PracticeRegion,
        sequence: Int,
        duration: TimeInterval
    ) throws -> Take {
        try Take(
            projectID: projectID,
            region: region,
            sequence: sequence,
            relativeAudioPath: "projects/\(projectID)/\(UUID()).caf",
            duration: duration,
            createdAt: Date(timeIntervalSince1970: TimeInterval(sequence))
        )
    }
}

struct SettingsStoreContract {
    let settings: any SettingsStore

    func assertRoundTripOverwriteAndDelete() async throws {
        let initial = try await settings.value(for: "countdown", as: Int.self)
        XCTAssertNil(initial)

        try await settings.set(3, for: "countdown")
        let first = try await settings.value(for: "countdown", as: Int.self)
        XCTAssertEqual(first, 3)

        try await settings.set(5, for: "countdown")
        let overwritten = try await settings.value(for: "countdown", as: Int.self)
        XCTAssertEqual(overwritten, 5)

        let deleted: Int? = nil
        try await settings.set(deleted, for: "countdown")
        let final = try await settings.value(for: "countdown", as: Int.self)
        XCTAssertNil(final)
    }

    func assertCodableValueRoundTrip() async throws {
        let value = TestSetting(playOriginal: true, playbackRate: 0.75)
        try await settings.set(value, for: "recording")

        let loaded = try await settings.value(for: "recording", as: TestSetting.self)
        XCTAssertEqual(loaded, value)
    }
}

private struct TestSetting: Codable, Equatable, Sendable {
    let playOriginal: Bool
    let playbackRate: Double
}

@MainActor
final class GRDBRepositoryContractTests: XCTestCase {
    func testProjectSaveUpdateAndLookupContract() async throws {
        let context = try makeContext()
        try await ProjectRepositoryContract(repository: context.projects)
            .assertSaveUpdateAndLookup()
    }

    func testProjectRecentOrderingAndLimitContract() async throws {
        let context = try makeContext()
        try await ProjectRepositoryContract(repository: context.projects)
            .assertRecentOrderingAndLimit()
    }

    func testProjectDeleteContract() async throws {
        let context = try makeContext()
        try await ProjectRepositoryContract(repository: context.projects).assertDelete()
    }

    func testTakeSaveUpdateOrderingAndDeleteContract() async throws {
        let context = try makeContext()
        try await TakeRepositoryContract(projects: context.projects, takes: context.takes)
            .assertSaveUpdateOrderingAndDelete()
    }

    func testProjectDeleteCascadesTakesContract() async throws {
        let context = try makeContext()
        try await TakeRepositoryContract(projects: context.projects, takes: context.takes)
            .assertProjectDeleteCascadesTakes()
    }

    func testSettingsRoundTripOverwriteAndDeleteContract() async throws {
        let context = try makeContext()
        try await SettingsStoreContract(settings: context.settings)
            .assertRoundTripOverwriteAndDelete()
    }

    func testSettingsCodableValueContract() async throws {
        let context = try makeContext()
        try await SettingsStoreContract(settings: context.settings)
            .assertCodableValueRoundTrip()
    }

    private func makeContext() throws -> RepositoryContractContext {
        let database = try DatabaseQueue()
        try AppDatabase.makeMigrator().migrate(database)
        return RepositoryContractContext(
            projects: GRDBProjectRepository(database: database),
            takes: GRDBTakeRepository(database: database),
            settings: GRDBSettingsStore(database: database)
        )
    }
}

@MainActor
final class InMemoryRepositoryContractTests: XCTestCase {
    func testProjectContract() async throws {
        let context = makeContext()
        let contract = ProjectRepositoryContract(repository: context.projects)
        try await contract.assertSaveUpdateAndLookup()
        try await contract.assertRecentOrderingAndLimit()
        try await contract.assertDelete()
    }

    func testTakeContract() async throws {
        let context = makeContext()
        let contract = TakeRepositoryContract(
            projects: context.projects,
            takes: context.takes
        )
        try await contract.assertSaveUpdateOrderingAndDelete()
        try await contract.assertProjectDeleteCascadesTakes()
    }

    func testSettingsContract() async throws {
        let context = makeContext()
        let contract = SettingsStoreContract(settings: context.settings)
        try await contract.assertRoundTripOverwriteAndDelete()
        try await contract.assertCodableValueRoundTrip()
    }

    private func makeContext() -> RepositoryContractContext {
        let storage = InMemoryPersistence()
        return RepositoryContractContext(
            projects: InMemoryProjectRepository(storage: storage),
            takes: InMemoryTakeRepository(storage: storage),
            settings: InMemorySettingsStore(storage: storage)
        )
    }
}
