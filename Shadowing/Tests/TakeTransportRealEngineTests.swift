@preconcurrency import AVFoundation
@testable import Shadowing
import XCTest

/// The practice screen's take transport on the REAL `PracticeAudioEngine`, rendering offline
/// (no audio device). The original is 40 s at level 0.3; the take is 3 s at level 0.8 and sits
/// on the waveform at 27.69–30.69 s, so rendered audio shows which one plays, and take time
/// (0–3 s) can never pass for waveform time (27.69 s on).
@MainActor
final class TakeTransportRealEngineTests: XCTestCase {
    private static let sampleRate: Double = 44100
    private static let takeStart: TimeInterval = 27.69

    private func makeFile(seconds: Double, level: Double) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("take-transport-\(UUID().uuidString).caf")
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: Self.sampleRate, channels: 1))
        let frames = AVAudioFrameCount(Self.sampleRate * seconds)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
        buffer.frameLength = frames
        let samples = try XCTUnwrap(buffer.floatChannelData?[0])
        for index in 0 ..< Int(frames) {
            samples[index] = Float(level * sin(2 * .pi * 440 * Double(index) / Self.sampleRate))
        }
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: buffer)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private struct Fixture {
        let model: PracticeViewModel
        let engine: PracticeAudioEngine
        let take: Take
    }

    private func makeFixture() async throws -> Fixture {
        let source = try makeFile(seconds: 40, level: 0.3)
        let takeURL = try makeFile(seconds: 3, level: 0.8)
        let engine = try PracticeAudioEngine.offlineRendering(
            sampleRate: Self.sampleRate,
            takeURLResolver: { _ in takeURL }
        )
        try await engine.execute(.loadSource(source))
        let project = AudioProject(
            id: UUID(),
            sourceDisplayName: "Speech.mp3",
            sourceBookmark: Data([7]),
            duration: 40,
            playhead: 5,
            currentRegion: nil,
            selectedTakeID: nil,
            keptTakeID: nil,
            lastOpenedAt: Date(timeIntervalSince1970: 100)
        )
        let model = PracticeViewModel(
            prepared: PreparedPractice(project: project, waveform: WaveformPresentation(peaks: [0.3], warning: nil)),
            audioClient: engine,
            projects: InMemoryProjectRepository(storage: InMemoryPersistence()),
            sessionPreparer: M7SessionPreparer()
        )
        model.start()
        await M7TestSupport.waitUntil { model.revealToken > 0 && model.pendingLocalSeek == nil }
        let take = try Take(
            id: UUID(),
            projectID: project.id,
            region: PracticeRegion(start: Self.takeStart, end: Self.takeStart + 3, sourceDuration: 40),
            sequence: 4,
            relativeAudioPath: "take.caf",
            duration: 3,
            createdAt: Date(timeIntervalSince1970: 50)
        )
        model.takes = [take]
        return Fixture(model: model, engine: engine, take: take)
    }

    /// Renders in 0.1 s slices, letting the engine's callbacks and the model's event task run
    /// between them; returns each slice's peak.
    @discardableResult
    private func render(_ fixture: Fixture, seconds: Double) async throws -> [Float] {
        var peaks: [Float] = []
        for _ in 0 ..< Int((seconds / 0.1).rounded()) {
            try await peaks.append(fixture.engine.renderOffline(frames: AVAudioFrameCount(Self.sampleRate * 0.1)))
            try await Task.sleep(for: .milliseconds(3))
        }
        return peaks
    }

    private func pressTakePlay(_ fixture: Fixture) async {
        fixture.model.toggleTakePlayback(fixture.take)
        await M7TestSupport.waitUntil { fixture.model.pendingLocalSeek == nil }
    }

    func testOnePressPlaysATakeAgainAfterItReachedItsEnd() async throws {
        let fixture = try await makeFixture()
        let model = fixture.model
        await pressTakePlay(fixture)
        XCTAssertTrue(model.isPlaying)
        try await render(fixture, seconds: 3.4) // past the take's end
        await M7TestSupport.waitUntil { !model.isPlaying }
        XCTAssertNil(model.playingTakeID)

        await pressTakePlay(fixture) // once
        let peaks = try await render(fixture, seconds: 0.5)
        XCTAssertTrue(model.isPlaying, "one press plays")
        XCTAssertEqual(model.playingTakeID, fixture.take.id)
        XCTAssertTrue(peaks.dropFirst().allSatisfy { $0 > 0.6 }, "the take is heard at once: \(peaks)")
        // Positions come on a wall-clock timer (30 Hz), so wait for the next one.
        await M7TestSupport.waitUntil { model.playhead > Self.takeStart + 0.3 }
        XCTAssertEqual(model.playhead, Self.takeStart + 0.5, accuracy: 0.15, "from the take's start")
    }

    func testPausingATakeLeavesThePlayheadWhereItStopped() async throws {
        let fixture = try await makeFixture()
        let model = fixture.model
        await pressTakePlay(fixture)
        try await render(fixture, seconds: 1.5)
        await M7TestSupport.waitUntil { model.playhead > Self.takeStart + 1.3 }
        let viewport = model.timelineViewport

        model.toggleTakePlayback(fixture.take) // pause
        await M7TestSupport.waitUntil { !model.isPlaying && model.pendingLocalSeek == nil }
        let paused = model.playhead
        try await Task.sleep(for: .milliseconds(120)) // any tick still on its way
        XCTAssertGreaterThan(paused, Self.takeStart + 1.3, "on the take, not near 0:00")
        XCTAssertEqual(model.playhead, paused, accuracy: 1e-9, "stays where it stopped")
        XCTAssertEqual(model.timelineViewport, viewport, "no scroll")
    }

    /// A timer tick that reaches the engine after the pause publishes nothing; before, it
    /// reported the original's old paused position.
    func testATickArrivingAfterAPausePublishesNothing() async throws {
        let fixture = try await makeFixture()
        await pressTakePlay(fixture)
        try await render(fixture, seconds: 1)
        fixture.model.toggleTakePlayback(fixture.take)
        await M7TestSupport.waitUntil { !fixture.model.isPlaying }
        let before = fixture.model.playhead

        await fixture.engine.publishPlayheadTick()
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(fixture.model.playhead, before, accuracy: 1e-9)
    }
}
