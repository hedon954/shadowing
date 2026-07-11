@preconcurrency import AVFoundation
@testable import Shadowing
import XCTest

final class WaveformProcessingTests: XCTestCase {
    func testGeneratesNormalizedMultiResolutionPeaksFromProgrammaticFixture() async throws {
        let fixture = try makeSineFixture(duration: 2, amplitude: 0.8)
        defer { removeFixture(fixture) }

        let waveform = try await WaveformPeakGenerator().generate(
            from: fixture,
            framesPerPeak: [256, 1024, 4096]
        )

        XCTAssertEqual(waveform.sampleRate, 48000, accuracy: 0.001)
        XCTAssertEqual(waveform.duration, 2, accuracy: 1 / 48000)
        XCTAssertEqual(waveform.levels.map(\.framesPerPeak), [256, 1024, 4096])
        XCTAssertEqual(waveform.levels[0].peaks.count, 375)
        XCTAssertEqual(waveform.levels[1].peaks.count, 94)
        XCTAssertEqual(waveform.levels[2].peaks.count, 24)
        for level in waveform.levels {
            XCTAssertTrue(level.peaks.allSatisfy { 0 ... 1 ~= $0 })
            XCTAssertEqual(level.peaks.max() ?? 0, 0.8, accuracy: 0.01)
        }
    }

    func testWaveformCacheRoundTripsAndInvalidatesChangedSource() async throws {
        let fixture = try makeSineFixture(duration: 0.5, amplitude: 0.4)
        defer { removeFixture(fixture) }
        let cacheDirectory = fixture.deletingLastPathComponent()
            .appendingPathComponent("cache", isDirectory: true)
        let cache = WaveformFileCache(directory: cacheDirectory)
        let waveform = try await WaveformPeakGenerator().generate(
            from: fixture,
            framesPerPeak: [512]
        )

        try await cache.store(waveform)
        let cachedWaveform = try await cache.load(for: waveform.fingerprint)
        XCTAssertEqual(cachedWaveform, waveform)

        let changedDate = Date(timeIntervalSince1970: 2_000_000_000)
        try FileManager.default.setAttributes(
            [.modificationDate: changedDate],
            ofItemAtPath: fixture.path
        )
        let changedFingerprint = try SourceFingerprint.make(for: fixture)
        XCTAssertNotEqual(changedFingerprint, waveform.fingerprint)
        let changedValue = try await cache.load(for: changedFingerprint)
        XCTAssertNil(changedValue)

        try await cache.remove(for: waveform.fingerprint)
        let removedValue = try await cache.load(for: waveform.fingerprint)
        XCTAssertNil(removedValue)
    }

    func testGenerationObservesCancellation() async throws {
        let fixture = try makeSineFixture(duration: 20, amplitude: 0.5)
        defer { removeFixture(fixture) }

        let task = Task {
            try await WaveformPeakGenerator().generate(
                from: fixture,
                framesPerPeak: [64, 256, 1024]
            )
        }
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("Expected waveform generation to be cancelled")
        } catch is CancellationError {
            // Expected.
        }
    }

    private func makeSineFixture(
        duration: TimeInterval,
        amplitude: Float
    ) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let url = directory.appendingPathComponent("fixture.caf", isDirectory: false)
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 48000,
            channels: 1,
            interleaved: false
        ) else {
            throw FixtureError.cannotCreateFormat
        }
        let file = try AVAudioFile(
            forWriting: url,
            settings: format.settings,
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )
        let totalFrames = Int(duration * format.sampleRate)
        var writtenFrames = 0
        while writtenFrames < totalFrames {
            let frameCount = min(1024, totalFrames - writtenFrames)
            guard let buffer = AVAudioPCMBuffer(
                pcmFormat: format,
                frameCapacity: AVAudioFrameCount(frameCount)
            ), let samples = buffer.floatChannelData?[0]
            else {
                throw FixtureError.cannotCreateBuffer
            }
            buffer.frameLength = AVAudioFrameCount(frameCount)
            for frame in 0 ..< frameCount {
                let time = Double(writtenFrames + frame) / format.sampleRate
                samples[frame] = amplitude * Float(sin(2 * Double.pi * 440 * time))
            }
            try file.write(from: buffer)
            writtenFrames += frameCount
        }
        return url
    }

    private func removeFixture(_ url: URL) {
        do {
            try FileManager.default.removeItem(at: url.deletingLastPathComponent())
        } catch {
            XCTFail("Could not remove generated fixture: \(error)")
        }
    }
}

private enum FixtureError: Error {
    case cannotCreateFormat
    case cannotCreateBuffer
}
