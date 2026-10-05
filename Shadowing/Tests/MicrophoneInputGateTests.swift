import Foundation
@testable import Shadowing
import XCTest

/// Recording runs on a throwaway input-only engine per take, created only once access is
/// granted. These tests use counting fakes instead of a real `AVAudioEngine`.
final class MicrophoneInputGateTests: XCTestCase {
    func testUndecidedAccessNeverCreatesARecorder() {
        let gate = makeGate(status: { .notDetermined })

        for _ in 0 ..< 3 {
            XCTAssertNil(gate.recorderIfAuthorized())
        }

        XCTAssertEqual(gate.recorderCreationCount, 0)
    }

    func testDeniedOrRestrictedAccessNeverCreatesARecorder() {
        for permission in [MicrophonePermissionState.denied, .restricted] {
            let gate = makeGate(status: { permission })

            XCTAssertNil(gate.recorderIfAuthorized())
            XCTAssertEqual(gate.recorderCreationCount, 0)
        }
    }

    func testEveryTakeGetsAFreshRecorder() throws {
        let gate = makeGate(status: { .authorized })

        let first = try XCTUnwrap(gate.recorderIfAuthorized())
        let second = try XCTUnwrap(gate.recorderIfAuthorized())

        XCTAssertFalse(first === second, "a recorder is thrown away after its take, never reused")
        XCTAssertEqual(gate.recorderCreationCount, 2)
    }

    func testAccessGrantedLaterIsSeenWithoutRestarting() {
        let status = PermissionStatusBox(.notDetermined)
        let gate = makeGate(status: { status.value })
        XCTAssertNil(gate.recorderIfAuthorized())

        // R asked for access (or the user allowed it in System Settings).
        status.value = .authorized

        XCTAssertNotNil(gate.recorderIfAuthorized())
        XCTAssertEqual(gate.recorderCreationCount, 1)
    }

    func testRealAudioEngineRefusesToExistUnderXCTest() {
        XCTAssertTrue(AppLaunchEnvironment.isRunningTests)
        XCTAssertThrowsError(try PracticeAudioEngine.live()) { error in
            XCTAssertEqual(error as? PracticeAudioEngineConstructionError, .unavailableUnderTests)
        }
        XCTAssertThrowsError(
            try PracticeAudioEngine.live(environment: ["XCTestConfigurationFilePath": "/tmp/t.xctestconfiguration"])
        )
    }

    private func makeGate(
        status: @escaping MicrophoneInputGate<FakeRecorderHandle>.StatusProvider
    ) -> MicrophoneInputGate<FakeRecorderHandle> {
        MicrophoneInputGate(status: status, makeRecorder: FakeRecorderHandle.init)
    }
}

private final class FakeRecorderHandle {}

private final class PermissionStatusBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: MicrophonePermissionState

    init(_ value: MicrophonePermissionState) {
        stored = value
    }

    var value: MicrophonePermissionState {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}
