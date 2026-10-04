import Foundation
@testable import Shadowing
import XCTest

@MainActor
final class LibraryNavigationTests: XCTestCase {
    func testXCTestHostUsesATemporaryDataFolder() throws {
        let environment = ["XCTestConfigurationFilePath": "/tmp/fake.xctestconfiguration"]
        let folder = try XCTUnwrap(AppLaunchEnvironment.testDataDirectory(environment: environment))
        XCTAssertTrue(folder.path.hasPrefix(FileManager.default.temporaryDirectory.path), folder.path)
        XCTAssertFalse(folder.path.contains("Application Support"), folder.path)

        var overridden = environment
        overridden[AppLaunchEnvironment.testDataDirectoryKey] = "/tmp/shadowing-fake-data"
        let directory = AppLaunchEnvironment.testDataDirectory(environment: overridden)
        XCTAssertEqual(directory?.path, "/tmp/shadowing-fake-data")
    }

    func testNormalLaunchIgnoresTheTestOverride() {
        let environment = [AppLaunchEnvironment.testDataDirectoryKey: "/tmp/shadowing-fake-data"]
        XCTAssertFalse(AppLaunchEnvironment.isRunningTests(environment: environment))
        XCTAssertNil(AppLaunchEnvironment.testDataDirectory(environment: environment))
        XCTAssertTrue(AppLaunchEnvironment.isRunningTests)
    }

    func testSidebarSubtitleCountsTakes() {
        let project = M9TestSupport.makeProject(name: "Talk.mp3", openedAt: 1)
        let none = LibraryProjectItem(project: project, takeCount: 0, lastRecordedAt: nil)
        let one = LibraryProjectItem(project: project, takeCount: 1, lastRecordedAt: nil)
        let three = LibraryProjectItem(project: project, takeCount: 3, lastRecordedAt: nil)

        XCTAssertEqual(LibraryRowSubtitle.accessibilityText(for: none), "No takes yet · 0:30")
        XCTAssertEqual(LibraryRowSubtitle.accessibilityText(for: one), "1 take · 0:30")
        XCTAssertEqual(LibraryRowSubtitle.accessibilityText(for: three), "3 takes · 0:30")
    }

    func testOpeningAnotherFileAsksThePracticeToLeaveFirst() async throws {
        let preparer = RecordingSessionPreparer()
        let navigation = try AppNavigationModel(
            dependencies: NavigationTestSupport.makeDependencies(testCase: self, preparer: preparer)
        )
        let current = M7TestSupport.makePreparedPractice(playhead: 0)
        navigation.openPrepared(current)
        await M9TestSupport.waitUntil { navigation.currentProjectID == current.project.id }

        var pendingLeave: (@MainActor () -> Void)?
        navigation.registerPracticeLeaveRequester { leave in
            pendingLeave = leave
        }
        let other = LibraryProjectItem(
            project: M9TestSupport.makeProject(name: "Other.mp3", openedAt: 2),
            takeCount: 0,
            lastRecordedAt: nil
        )

        navigation.openLibraryItem(other)
        XCTAssertNotNil(pendingLeave, "the open practice must decide first (it may be recording)")
        XCTAssertEqual(navigation.selectedProjectID, other.id)
        let preparedBeforeLeaving = await preparer.preparedProjectIDs
        XCTAssertTrue(preparedBeforeLeaving.isEmpty, "loading must wait until the practice has closed")

        navigation.practiceLeaveCancelled()
        XCTAssertEqual(navigation.selectedProjectID, current.project.id)

        navigation.openLibraryItem(other)
        pendingLeave?()
        XCTAssertNil(navigation.preparedPractice)
        await M9TestSupport.waitUntil { navigation.currentProjectID == other.id }
        let prepared = await preparer.preparedProjectIDs
        XCTAssertEqual(prepared, [other.id])
    }

    func testDroppingAFileWithoutPracticeLoadsItDirectly() async throws {
        let preparer = RecordingSessionPreparer()
        let navigation = try AppNavigationModel(
            dependencies: NavigationTestSupport.makeDependencies(testCase: self, preparer: preparer)
        )
        XCTAssertTrue(navigation.acceptDroppedFiles([URL(fileURLWithPath: "/tmp/Dropped.mp3")]))
        await M9TestSupport.waitUntil { navigation.preparedPractice != nil }
        XCTAssertEqual(navigation.preparedPractice?.project.sourceDisplayName, "Dropped.mp3")
        XCTAssertFalse(navigation.acceptDroppedFiles([]))
    }
}
