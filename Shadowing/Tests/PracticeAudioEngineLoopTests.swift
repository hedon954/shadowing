@preconcurrency import AVFoundation
@testable import Shadowing
import XCTest

/// The REAL `PracticeAudioEngine` (AVAudioEngine, player nodes, time-pitch, loop scheduling)
/// rendering offline, so no audio device is touched. The source has a different level in each
/// part, so the rendered audio shows what actually plays:
/// 0–2 s before the loop (0.3), 2–3 s the loop (0.8), 3–10 s after it (0.05).
final class PracticeAudioEngineLoopTests: XCTestCase {
    private static let sampleRate: Double = 44100
    private let loop = try! PracticeRegion(start: 2, end: 3, sourceDuration: 10) // swiftlint:disable:this force_try

    private enum Part: Equatable, CustomStringConvertible {
        case before, loop, after, silence

        var description: String {
            switch self {
            case .before: "B"
            case .loop: "L"
            case .after: "A"
            case .silence: "-"
            }
        }
    }

    private func makeSource() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("engine-loop-\(UUID().uuidString).caf")
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: Self.sampleRate, channels: 1))
        let frames = AVAudioFrameCount(Self.sampleRate * 10)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
        buffer.frameLength = frames
        let samples = try XCTUnwrap(buffer.floatChannelData?[0])
        for index in 0 ..< Int(frames) {
            let time = Double(index) / Self.sampleRate
            let level: Double = time < 2 ? 0.3 : time < 3 ? 0.8 : 0.05
            samples[index] = Float(level * sin(2 * .pi * 440 * time))
        }
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: buffer)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func makeEngine() async throws -> PracticeAudioEngine {
        let engine = try PracticeAudioEngine.offlineRendering(sampleRate: Self.sampleRate)
        try await engine.execute(.loadSource(makeSource()))
        return engine
    }

    /// Renders `seconds` of output in short chunks (letting the loop re-queue callbacks run, as
    /// they would live) and returns which part of the source each chunk played.
    private func render(_ engine: PracticeAudioEngine, seconds: Double) async throws -> [Part] {
        var parts: [Part] = []
        let chunk = 0.1
        for _ in 0 ..< Int((seconds / chunk).rounded()) {
            let peak = try await engine.renderOffline(frames: AVAudioFrameCount(Self.sampleRate * chunk))
            parts.append(peak > 0.45 ? .loop : peak > 0.12 ? .before : peak > 0.015 ? .after : .silence)
            try await Task.sleep(for: .milliseconds(2))
        }
        return parts
    }

    private func position(_ engine: PracticeAudioEngine) async -> TimeInterval {
        await Double(engine.currentSourceFrame()) / Self.sampleRate
    }

    /// While playing, the reported position runs up to one render slice (4096 frames, ~0.093 s)
    /// ahead of what was rendered: the time-pitch unit reads ahead. Never behind.
    private func assertPlaying(
        _ reported: TimeInterval,
        at expected: TimeInterval,
        _ message: String = "",
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertGreaterThanOrEqual(reported, expected - 0.01, message, file: file, line: line)
        XCTAssertLessThanOrEqual(reported, expected + 0.11, message, file: file, line: line)
    }

    func testPausedSeekOutsideTheLoopKeepsThePosition() async throws {
        let engine = try await makeEngine()
        try await engine.execute(.setLoop(loop))
        try await engine.execute(.seek(1))
        var reported = await position(engine)
        XCTAssertEqual(reported, 1, accuracy: 0.001, "before the loop: not pulled to its start")

        try await engine.execute(.seek(7))
        try await engine.execute(.setLoop(loop))
        reported = await position(engine)
        XCTAssertEqual(reported, 7, accuracy: 0.001, "after the loop, also when the loop is set again")
    }

    func testPlayingFromBeforeTheLoopPlaysIntoItAndThenLoops() async throws {
        let engine = try await makeEngine()
        try await engine.execute(.setLoop(loop))
        try await engine.execute(.seek(1))
        try await engine.execute(.playOriginal(region: loop, from: 1, rate: 1))

        let lead = try await render(engine, seconds: 0.8) // 1.0–1.8 s
        XCTAssertEqual(lead.dropFirst().filter { $0 != .before }, [], "starts at 1.0, before the loop: \(lead)")
        _ = try await render(engine, seconds: 0.4) // into the loop
        var reported = await position(engine)
        assertPlaying(reported, at: 2.2)

        // 2.2 s onwards: three more passes of the loop, never the part after it.
        let looping = try await render(engine, seconds: 3)
        XCTAssertEqual(looping.filter { $0 != .loop }, [], "keeps looping 2–3 s: \(looping)")
        reported = await position(engine)
        XCTAssertGreaterThanOrEqual(reported, 2)
        XCTAssertLessThan(reported, 3)
        assertPlaying(reported, at: 2.2, "5.2 s played = 2.2 s after three loops")
        try await engine.execute(.pause)
    }

    func testPlayingFromAfterTheLoopPlaysOnWithoutJumpingBack() async throws {
        let engine = try await makeEngine()
        try await engine.execute(.setLoop(loop))
        try await engine.execute(.seek(5))
        try await engine.execute(.playOriginal(region: loop, from: 5, rate: 1))

        let parts = try await render(engine, seconds: 2)
        XCTAssertEqual(parts.filter { $0 != .after }, [], "plays 5–7 s, never the loop: \(parts)")
        let reported = await position(engine)
        assertPlaying(reported, at: 7, "position keeps counting past the loop's end")
        try await engine.execute(.pause)
        let paused = await position(engine)
        XCTAssertEqual(paused, reported, accuracy: 0.001, "pausing keeps it there, not at the loop")
    }

    func testPlayingFromExactlyTheLoopEndPlaysOn() async throws {
        let engine = try await makeEngine()
        try await engine.execute(.setLoop(loop))
        try await engine.execute(.playOriginal(region: loop, from: 3, rate: 1))

        let parts = try await render(engine, seconds: 1)
        XCTAssertEqual(parts.dropFirst().filter { $0 != .after }, [], "3–4 s, no jump back: \(parts)")
        let reported = await position(engine)
        assertPlaying(reported, at: 4)
        try await engine.execute(.pause)
    }
}
