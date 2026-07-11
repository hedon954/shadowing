@testable import Shadowing
import XCTest

@MainActor
final class RecordingStartPositionTests: XCTestCase {
    func testRecordingWithoutSelectionStartsAtCurrentPlayheadUntilSourceEnd() async throws {
        let fixture = try await M9TestSupport.makeFixture(
            testCase: self,
            selectRegion: false
        )
        fixture.viewModel.seek(to: 12)
        await M9TestSupport.waitForCommand(.seek(12), audio: fixture.audio)

        fixture.viewModel.startRecording()
        let temporaryURL = await M9TestSupport.waitForBeginRecording(audio: fixture.audio)

        let commands = await fixture.audio.commands
        guard case let .beginRecording(region, _, _) = commands.last else {
            return XCTFail("Expected beginRecording command")
        }
        XCTAssertEqual(region.start, 12, accuracy: 0.001)
        XCTAssertEqual(region.end, 30, accuracy: 0.001)
        XCTAssertNil(fixture.viewModel.region)
        XCTAssertFalse(fixture.viewModel.loopEnabled)

        try Data([1, 2, 3, 4]).write(to: temporaryURL)
        await fixture.audio.emit(.recordingStarted)
        await fixture.audio.emit(
            .recordingFinished(
                url: temporaryURL,
                duration: 2,
                reason: .manual
            )
        )
        await M9TestSupport.waitUntil { fixture.viewModel.isComparing }
        await M9TestSupport.waitUntil {
            fixture.viewModel.recordingPresentation == .idle
        }

        let take = try XCTUnwrap(fixture.viewModel.activeTake)
        XCTAssertEqual(take.duration, 2, accuracy: 0.001)
        XCTAssertEqual(take.region.start, 12, accuracy: 0.001)
        XCTAssertEqual(take.region.end, 14, accuracy: 0.001)
        XCTAssertNil(fixture.viewModel.region)
    }

    func testRecordingStartsAtSeekedOriginalPlayhead() async throws {
        let fixture = try await M9TestSupport.makeFixture(
            testCase: self,
            selectRegion: false
        )
        fixture.viewModel.seek(to: 12)
        await M9TestSupport.waitForCommand(.seek(12), audio: fixture.audio)

        fixture.viewModel.startRecording()
        _ = await M9TestSupport.waitForBeginRecording(audio: fixture.audio)

        let commands = await fixture.audio.commands
        guard case let .beginRecording(region, _, _) = commands.last else {
            return XCTFail("Expected beginRecording command")
        }
        XCTAssertEqual(region.start, 12, accuracy: 0.001)
        XCTAssertEqual(fixture.viewModel.playhead, 12, accuracy: 0.001)
    }

    func testRecordingIgnoresPracticeLoopSelectionAsLimit() async throws {
        let fixture = try await M9TestSupport.makeFixture(testCase: self)
        // selectRegion seeks playhead to region.start (4); loop is 4–7.
        fixture.viewModel.startRecording()
        _ = await M9TestSupport.waitForBeginRecording(audio: fixture.audio)

        let commands = await fixture.audio.commands
        guard case let .beginRecording(region, _, _) = commands.last else {
            return XCTFail("Expected beginRecording command")
        }
        XCTAssertEqual(region.start, fixture.region.start, accuracy: 0.001)
        XCTAssertEqual(region.end, 30, accuracy: 0.001)
        XCTAssertNotEqual(region.end, fixture.region.end, accuracy: 0.001)
        XCTAssertEqual(fixture.viewModel.region, fixture.region)
    }

    func testRecordingNearSourceEndProvidesMinimumValidWindow() async throws {
        let fixture = try await M9TestSupport.makeFixture(
            testCase: self,
            selectRegion: false
        )
        fixture.viewModel.seek(to: 30)
        await M9TestSupport.waitForCommand(.seek(30), audio: fixture.audio)

        fixture.viewModel.startRecording()
        _ = await M9TestSupport.waitForBeginRecording(audio: fixture.audio)

        let commands = await fixture.audio.commands
        guard case let .beginRecording(region, _, _) = commands.last else {
            return XCTFail("Expected beginRecording command")
        }
        XCTAssertEqual(region.start, 29.5, accuracy: 0.001)
        XCTAssertEqual(region.end, 30, accuracy: 0.001)
    }

    func testEarlyStopShortensTakeToRecordedDurationWithoutChangingLoop() async throws {
        let fixture = try await M9TestSupport.makeFixture(testCase: self)

        fixture.viewModel.startRecording()
        let temporaryURL = await M9TestSupport.waitForBeginRecording(audio: fixture.audio)
        try Data([1, 2, 3, 4]).write(to: temporaryURL)
        await fixture.audio.emit(.recordingStarted)
        await fixture.audio.emit(
            .recordingFinished(
                url: temporaryURL,
                duration: 1.4,
                reason: .manual
            )
        )
        await M9TestSupport.waitUntil { fixture.viewModel.isComparing }
        await M9TestSupport.waitUntil {
            fixture.viewModel.recordingPresentation == .idle
        }

        let take = try XCTUnwrap(fixture.viewModel.activeTake)
        XCTAssertEqual(take.duration, 1.4, accuracy: 0.001)
        XCTAssertEqual(take.region.start, fixture.region.start, accuracy: 0.001)
        XCTAssertEqual(take.region.duration, 1.4, accuracy: 0.001)
        XCTAssertEqual(fixture.viewModel.region, fixture.region)
    }

    func testCancelWhileCheckingMicrophoneAbortsArmedEngineSession() async throws {
        let fixture = try await M9TestSupport.makeFixture(
            testCase: self,
            countdownSeconds: 3
        )
        fixture.viewModel.startRecording()
        await M9TestSupport.waitUntil {
            if case .countingDown = fixture.viewModel.recordingPresentation {
                return true
            }
            return false
        }

        fixture.viewModel.stopRecording()
        await M9TestSupport.waitUntil {
            fixture.viewModel.recordingPresentation == .idle
        }

        let commands = await fixture.audio.commands
        XCTAssertTrue(commands.contains(.abortRecording))
        XCTAssertFalse(fixture.viewModel.controlsLocked)

        let commandCount = commands.count
        fixture.viewModel.startRecording()
        _ = await M9TestSupport.waitForBeginRecording(
            audio: fixture.audio,
            afterCommandCount: commandCount
        )
        let latest = await fixture.audio.commands
        let beginCount = latest.suffix(from: commandCount).filter { command in
            if case .beginRecording = command {
                return true
            }
            return false
        }.count
        XCTAssertEqual(beginCount, 1)
    }

    func testStaleRecordingStartedAfterCancelDoesNotReenterRecording() async throws {
        let fixture = try await M9TestSupport.makeFixture(
            testCase: self,
            countdownSeconds: 3
        )
        fixture.viewModel.startRecording()
        await M9TestSupport.waitUntil {
            if case .countingDown = fixture.viewModel.recordingPresentation {
                return true
            }
            return false
        }
        fixture.viewModel.stopRecording()
        await M9TestSupport.waitUntil {
            fixture.viewModel.recordingPresentation == .idle
        }

        await fixture.audio.emit(.recordingStarted)
        await Task.yield()
        XCTAssertEqual(fixture.viewModel.recordingPresentation, .idle)
    }
}
