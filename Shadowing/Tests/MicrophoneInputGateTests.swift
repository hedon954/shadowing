import Foundation
@testable import Shadowing
import XCTest

/// Creating the audio engine's microphone input makes macOS ask for access and keeps the
/// microphone in use on every later start of that engine. These tests use counting fakes instead
/// of a real `AVAudioEngine`.
final class MicrophoneInputGateTests: XCTestCase {
    func testUndecidedAccessNeverCreatesTheInput() {
        let gate = makeGate(status: { .notDetermined })

        for _ in 0 ..< 3 {
            XCTAssertNil(gate.inputIfAuthorized())
        }

        XCTAssertEqual(gate.inputCreationCount, 0)
        XCTAssertNil(gate.existingInput)
        XCTAssertFalse(gate.engine.hasInput)
    }

    func testDeniedOrRestrictedAccessNeverCreatesTheInput() {
        for permission in [MicrophonePermissionState.denied, .restricted] {
            let gate = makeGate(status: { permission })

            XCTAssertNil(gate.inputIfAuthorized())
            XCTAssertEqual(gate.inputCreationCount, 0)
            XCTAssertFalse(gate.engine.hasInput)
        }
    }

    func testGrantedAccessCreatesTheInputOnceAndReusesIt() throws {
        let gate = makeGate(status: { .authorized })

        let first = try XCTUnwrap(gate.inputIfAuthorized())
        let second = try XCTUnwrap(gate.inputIfAuthorized())

        XCTAssertTrue(first === second)
        XCTAssertEqual(gate.inputCreationCount, 1)
        XCTAssertTrue(gate.engine.hasInput)
    }

    func testAccessGrantedLaterIsSeenWithoutRebuildingTheEngine() {
        let status = PermissionStatusBox(.notDetermined)
        let gate = makeGate(status: { status.value })
        XCTAssertNil(gate.inputIfAuthorized())

        // R asked for access (or the user allowed it in System Settings).
        status.value = .authorized

        XCTAssertNotNil(gate.inputIfAuthorized())
        XCTAssertEqual(gate.inputCreationCount, 1)
    }

    func testPlaybackEngineHasNoInputAfterARecordingEnds() throws {
        let gate = makeGate(status: { .authorized })
        let recordingEngine = gate.engine
        XCTAssertNotNil(gate.inputIfAuthorized())

        let retired = try XCTUnwrap(gate.replaceEngineIfItHasInput())

        XCTAssertTrue(retired === recordingEngine)
        XCTAssertFalse(gate.engine === recordingEngine)
        XCTAssertFalse(gate.engine.hasInput, "Playback after a take must not run on an engine with an input")
        XCTAssertNil(gate.existingInput)
        XCTAssertEqual(gate.engineReplacementCount, 1)
    }

    func testEngineWithoutInputIsKeptWhenNothingWasRecorded() {
        let gate = makeGate(status: { .notDetermined })
        let playbackEngine = gate.engine

        XCTAssertNil(gate.inputIfAuthorized())
        XCTAssertNil(gate.replaceEngineIfItHasInput())

        XCTAssertTrue(gate.engine === playbackEngine)
        XCTAssertEqual(gate.engineReplacementCount, 0)
    }

    func testEachRecordingGetsAnInputAndPlaybackAlwaysEndsWithoutOne() {
        let gate = makeGate(status: { .authorized })

        for take in 1 ... 2 {
            XCTAssertNotNil(gate.inputIfAuthorized())
            XCTAssertTrue(gate.engine.hasInput)
            XCTAssertNotNil(gate.replaceEngineIfItHasInput())
            XCTAssertFalse(gate.engine.hasInput)
            XCTAssertEqual(gate.inputCreationCount, take)
        }
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
        status: @escaping MicrophoneInputGate<FakeAudioEngine, FakeInput>.StatusProvider
    ) -> MicrophoneInputGate<FakeAudioEngine, FakeInput> {
        MicrophoneInputGate(
            engine: FakeAudioEngine(),
            status: status,
            makeEngine: FakeAudioEngine.init,
            makeInput: { engine in
                engine.hasInput = true
                return FakeInput()
            }
        )
    }
}

/// Stands in for `AVAudioEngine`: records whether its input was ever created.
private final class FakeAudioEngine {
    var hasInput = false
}

private final class FakeInput {}

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
