@preconcurrency import AVFoundation
@testable import Shadowing
import XCTest

/// A take with a fake microphone feeding a real file writer: no audio, an empty take, a
/// configuration change and a hung close must all end without waiting forever.
final class MicrophoneTakeTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MicrophoneTakeTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func testNoBufferWithinTheTimeoutIsReportedAndSavesNothing() async throws {
        let microphone = FakeMicrophone()
        let take = try makeTake(microphone)

        let started = ContinuousClock.now
        let gotAudio = await take.pipeline.waitForFirstBuffer(
            timeout: .milliseconds(200),
            pollInterval: .milliseconds(10)
        )
        XCTAssertFalse(gotAudio)
        XCTAssertLessThan(ContinuousClock.now - started, .seconds(2))

        take.stopInput()
        let result = try await take.pipeline.finishKeepingAudio(timeout: .seconds(3))

        XCTAssertNil(result, "0 frames must not become a take")
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path), "the empty file is deleted")
        XCTAssertEqual(microphone.stopCount, 1)
    }

    func testAudioIsWrittenAndKept() async throws {
        let microphone = FakeMicrophone()
        let take = try makeTake(microphone)

        for _ in 0 ..< 5 {
            microphone.deliver(frames: 4410)
        }
        let gotAudio = await take.pipeline.waitForFirstBuffer(timeout: .seconds(1))
        XCTAssertTrue(gotAudio)
        take.stopInput()
        let kept = try await take.pipeline.finishKeepingAudio(timeout: .seconds(3))
        let result = try XCTUnwrap(kept)

        XCTAssertEqual(result.duration, 0.5, accuracy: 0.001)
        let size = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: destination.path)[.size] as? Int)
        XCTAssertGreaterThan(size, 4096, "more than an empty CAF header")
    }

    func testConfigurationChangeIsReportedAndTheInputRestarted() throws {
        let microphone = FakeMicrophone()
        let changes = Counter()
        let take = try makeTake(microphone) { changes.increment() }

        microphone.simulateConfigurationChange()

        XCTAssertEqual(changes.value, 1)
        XCTAssertTrue(take.restartAfterConfigurationChange())
        XCTAssertEqual(microphone.restartCount, 1)
    }

    func testInputThatCannotRestartEndsTheTake() throws {
        let microphone = FakeMicrophone()
        microphone.restartError = PracticeAudioEngineError.inputUnavailable
        let take = try makeTake(microphone)

        XCTAssertFalse(take.restartAfterConfigurationChange())
    }

    func testInputThatFailsToStartIsStoppedAgain() {
        let microphone = FakeMicrophone()
        microphone.startError = PracticeAudioEngineError.audioEngineFailed("no device")

        XCTAssertThrowsError(try makeTake(microphone))
        XCTAssertEqual(microphone.stopCount, 1)
    }

    func testTimeoutStopsWaitingForAnOperationThatNeverReturns() async {
        let started = ContinuousClock.now
        do {
            let _: Int = try await AsyncTimeout.run(.milliseconds(100)) {
                // Never resumes and ignores cancellation, like a stuck audio callback.
                await withUnsafeContinuation { (_: UnsafeContinuation<Int, Never>) in }
            }
            XCTFail("expected a timeout")
        } catch {
            XCTAssertEqual(error as? AsyncTimeout.Expired, AsyncTimeout.Expired())
        }
        XCTAssertLessThan(ContinuousClock.now - started, .seconds(2))
    }

    func testTimeoutReturnsAFastOperationsValue() async throws {
        let value = try await AsyncTimeout.run(.seconds(5)) { 42 }
        XCTAssertEqual(value, 42)
    }

    // MARK: - Helpers

    private var destination: URL {
        directory.appendingPathComponent("take.caf")
    }

    private func makeTake(
        _ microphone: FakeMicrophone,
        onConfigurationChange: @escaping @Sendable () -> Void = {}
    ) throws -> MicrophoneTake {
        try MicrophoneTake(
            recorder: microphone,
            destinationURL: destination,
            maximumDuration: nil,
            clock: RecordingAlignmentClock(),
            onConfigurationChange: onConfigurationChange
        )
    }
}

/// Stands in for `MicrophoneRecorder`: buffers arrive only when the test delivers them.
private final class FakeMicrophone: MicrophoneCapturing, @unchecked Sendable {
    let format = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 1)!
    var startError: Error?
    var restartError: Error?
    private(set) var restartCount = 0
    private(set) var stopCount = 0
    private var onBuffer: (@Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void)?
    private var onConfigurationChange: (@Sendable () -> Void)?

    func inputFormat() throws -> AVAudioFormat {
        format
    }

    func start(
        onBuffer: @escaping @Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void,
        onConfigurationChange: @escaping @Sendable () -> Void
    ) throws {
        if let startError {
            throw startError
        }
        self.onBuffer = onBuffer
        self.onConfigurationChange = onConfigurationChange
    }

    func restart() throws {
        restartCount += 1
        if let restartError {
            throw restartError
        }
    }

    func stop() {
        stopCount += 1
        onBuffer = nil
        onConfigurationChange = nil
    }

    var inputLatency: TimeInterval? {
        nil
    }

    func deliver(frames: AVAudioFrameCount) {
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        if let samples = buffer.floatChannelData?[0] {
            for index in 0 ..< Int(frames) {
                samples[index] = sin(Float(index) * 0.06) * 0.3
            }
        }
        onBuffer?(buffer, AVAudioTime(hostTime: mach_absolute_time()))
    }

    func simulateConfigurationChange() {
        onConfigurationChange?()
    }
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var stored = 0

    var value: Int {
        lock.withLock { stored }
    }

    func increment() {
        lock.withLock { stored += 1 }
    }
}
