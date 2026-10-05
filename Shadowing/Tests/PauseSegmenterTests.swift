import AVFoundation
@testable import Shadowing
import XCTest

/// Sentences from pauses, checked against generated audio (tone, silence, tone). No real files.
final class PauseSegmenterTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PauseSegmenterTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    /// Writes mono 44.1 kHz audio: each part is (seconds, amplitude) of a 220 Hz tone; 0 is silence.
    private func makeAudio(_ parts: [(TimeInterval, Float)]) throws -> URL {
        let sampleRate = 44100.0
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1))
        let url = directory.appendingPathComponent("generated.caf")
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        var phase = 0.0
        for (seconds, amplitude) in parts {
            let frames = AVAudioFrameCount(seconds * sampleRate)
            let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
            buffer.frameLength = frames
            let samples = try XCTUnwrap(buffer.floatChannelData?[0])
            for index in 0 ..< Int(frames) {
                samples[index] = amplitude * Float(sin(phase))
                phase += 2 * .pi * 220 / sampleRate
            }
            try file.write(from: buffer)
        }
        return url
    }

    private func waveform(of url: URL) async throws -> WaveformPresentation {
        let data = try await WaveformPeakGenerator().generate(from: url)
        return WaveformPresentation(
            duration: data.duration,
            sampleRate: data.sampleRate,
            levels: data.levels,
            warning: nil
        )
    }

    func testToneSilenceToneMakesTwoSentences() async throws {
        let url = try makeAudio([(1.0, 0.6), (0.8, 0), (1.2, 0.5)])
        let chunks = try await PauseSegmenter.chunks(in: waveform(of: url))
        XCTAssertEqual(chunks.count, 2, "\(chunks)")
        XCTAssertEqual(chunks[0].start, 0, accuracy: 0.02)
        XCTAssertEqual(chunks[0].end, 1.08, accuracy: 0.05)
        XCTAssertEqual(chunks[1].start, 1.72, accuracy: 0.05)
        XCTAssertEqual(chunks[1].end, 3.0, accuracy: 0.02)
    }

    func testShortPauseDoesNotSplitAndShortBlipJoinsItsNeighbour() async throws {
        let url = try makeAudio([(1.0, 0.6), (0.15, 0), (1.0, 0.6), (0.6, 0), (0.1, 0.6), (0.6, 0)])
        let chunks = try await PauseSegmenter.chunks(in: waveform(of: url))
        XCTAssertEqual(chunks.count, 1, "\(chunks)")
        XCTAssertEqual(chunks[0].start, 0, accuracy: 0.02)
        XCTAssertEqual(chunks[0].end, 2.93, accuracy: 0.06)
    }

    func testQuietRecordingStillSplitsRelativeToItsOwnLevel() async throws {
        let url = try makeAudio([(0.3, 0), (1.0, 0.05), (0.7, 0.001), (1.0, 0.05)])
        let chunks = try await PauseSegmenter.chunks(in: waveform(of: url))
        XCTAssertEqual(chunks.count, 2, "\(chunks)")
        XCTAssertEqual(chunks[0].start, 0.22, accuracy: 0.05)
    }

    func testChunkAtTimePrefersTheSentenceUnderThePlayhead() {
        let chunks = [SentenceChunk(start: 0, end: 1), SentenceChunk(start: 2, end: 3)]
        XCTAssertEqual(PauseSegmenter.chunk(at: 0.5, in: chunks), chunks[0])
        XCTAssertEqual(PauseSegmenter.chunk(at: 1.5, in: chunks), chunks[1], "a pause plays the next sentence")
        XCTAssertEqual(PauseSegmenter.chunk(at: 9, in: chunks), chunks[1])
        XCTAssertNil(PauseSegmenter.chunk(at: 1, in: []))
    }

    func testCutsAreCachedNextToTheWaveformCache() async throws {
        let url = try makeAudio([(1.0, 0.6), (0.8, 0), (1.2, 0.5)])
        let waveform = try await waveform(of: url)
        let cache = CachedPauseChunks(directory: directory.appendingPathComponent("Waveforms"))
        let projectID = UUID()
        let first = await cache.chunks(projectID: projectID, waveform: waveform)
        let file = await cache.cacheURL(projectID: projectID, waveform: waveform)
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))

        let planted = [SentenceChunk(start: 0.5, end: 1.5)]
        try JSONEncoder().encode(planted).write(to: file)
        let second = await cache.chunks(projectID: projectID, waveform: waveform)
        XCTAssertEqual(second, planted, "second call reads the cache")
        XCTAssertEqual(first.count, 2)

        try Data("not json".utf8).write(to: file)
        let rebuilt = await cache.chunks(projectID: projectID, waveform: waveform)
        XCTAssertEqual(rebuilt, first, "a broken cache is rebuilt, never an error")
    }
}
