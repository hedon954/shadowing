@preconcurrency import AVFoundation
import Foundation
@testable import Shadowing
import XCTest

final class TakeAudioSplicerTests: XCTestCase {
    func testMidOverwriteMergesHeadInsertAndTail() throws {
        let existing = try makeFixture(duration: 1.0, amplitude: 0.4)
        let incoming = try makeFixture(duration: 0.3, amplitude: 0.9)
        defer {
            removeFixture(existing)
            removeFixture(incoming)
        }

        let plan = TakeOverwritePlan.planning(
            previousStart: 10,
            previousDuration: 1.0,
            newStart: 10.3,
            newDuration: 0.3
        )
        XCTAssertTrue(plan.needsSplice)
        XCTAssertEqual(plan.headDuration, 0.3, accuracy: 0.0001)
        XCTAssertEqual(plan.tailDuration, 0.4, accuracy: 0.0001)

        let output = existing.deletingLastPathComponent()
            .appendingPathComponent("merged.caf", isDirectory: false)
        try TakeAudioSplicer.merge(
            existingURL: existing,
            newRecordingURL: incoming,
            plan: plan,
            outputURL: output
        )

        let merged = try AVAudioFile(forReading: output)
        let expectedFrames = Int64((plan.resultDuration * merged.processingFormat.sampleRate)
            .rounded(.towardZero))
        XCTAssertLessThanOrEqual(abs(merged.length - expectedFrames), 2)
    }

    func testNonOverlappingAfterKeepsOriginalAlignmentWithSilence() throws {
        let existing = try makeFixture(duration: 0.2, amplitude: 0.4)
        let incoming = try makeFixture(duration: 0.2, amplitude: 0.9)
        defer {
            removeFixture(existing)
            removeFixture(incoming)
        }

        // Old take at 1.0–1.2, new recording at 2.0–2.2 → 0.8s silence in the middle.
        let plan = TakeOverwritePlan.planning(
            previousStart: 1.0,
            previousDuration: 0.2,
            newStart: 2.0,
            newDuration: 0.2
        )
        XCTAssertEqual(plan.resultDuration, 1.2, accuracy: 0.0001)
        XCTAssertEqual(plan.silenceDuration, 0.8, accuracy: 0.0001)

        let output = existing.deletingLastPathComponent()
            .appendingPathComponent("gap-merged.caf", isDirectory: false)
        try TakeAudioSplicer.merge(
            existingURL: existing,
            newRecordingURL: incoming,
            plan: plan,
            outputURL: output
        )

        let merged = try AVAudioFile(forReading: output)
        let sampleRate = merged.processingFormat.sampleRate
        let expectedFrames = Int64((plan.resultDuration * sampleRate).rounded(.towardZero))
        XCTAssertLessThanOrEqual(abs(merged.length - expectedFrames), 2)

        // Peak energy after the silence gap should land near the new recording.
        let peaks = try readAbsolutePeaks(from: merged, windowCount: 12)
        let earlyMax = peaks.prefix(2).max() ?? 0
        let midMax = peaks.dropFirst(3).prefix(5).max() ?? 0
        let lateMax = peaks.suffix(2).max() ?? 0
        XCTAssertGreaterThan(earlyMax, 0.05)
        XCTAssertLessThan(midMax, 0.02)
        XCTAssertGreaterThan(lateMax, 0.05)
    }

    func testMergeSurvivesDurationSlightlyLongerThanFile() throws {
        let existing = try makeFixture(duration: 0.5, amplitude: 0.3)
        let incoming = try makeFixture(duration: 0.5, amplitude: 0.7)
        defer {
            removeFixture(existing)
            removeFixture(incoming)
        }

        // Ask for a slightly longer head than the file can provide; reader must clamp
        // and pad so the result duration still matches the plan.
        let plan = TakeOverwritePlan(
            resultStart: 0,
            resultDuration: 1.05,
            segments: [
                TakeOverwriteSegment(duration: 0.55, source: .previous(localStart: 0)),
                TakeOverwriteSegment(duration: 0.5, source: .incoming(localStart: 0))
            ]
        )
        let output = existing.deletingLastPathComponent()
            .appendingPathComponent("clamped.caf", isDirectory: false)
        XCTAssertNoThrow(
            try TakeAudioSplicer.merge(
                existingURL: existing,
                newRecordingURL: incoming,
                plan: plan,
                outputURL: output
            )
        )
        let merged = try AVAudioFile(forReading: output)
        let expectedFrames = Int64((plan.resultDuration * merged.processingFormat.sampleRate)
            .rounded(.towardZero))
        XCTAssertLessThanOrEqual(abs(merged.length - expectedFrames), 2)
    }

    private func readAbsolutePeaks(
        from file: AVAudioFile,
        windowCount: Int
    ) throws -> [Float] {
        let format = file.processingFormat
        let totalFrames = AVAudioFrameCount(file.length)
        guard totalFrames > 0, windowCount > 0 else {
            return []
        }
        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: totalFrames
        ) else {
            throw FixtureError.cannotCreateBuffer
        }
        file.framePosition = 0
        try file.read(into: buffer)
        guard let samples = buffer.floatChannelData?[0] else {
            throw FixtureError.cannotCreateBuffer
        }
        let frames = Int(buffer.frameLength)
        var peaks: [Float] = []
        peaks.reserveCapacity(windowCount)
        for window in 0 ..< windowCount {
            let start = window * frames / windowCount
            let end = (window + 1) * frames / windowCount
            var peak: Float = 0
            for frame in start ..< end {
                peak = max(peak, abs(samples[frame]))
            }
            peaks.append(peak)
        }
        return peaks
    }

    private func makeFixture(duration: TimeInterval, amplitude: Float) throws -> URL {
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
        try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
    }
}

private enum FixtureError: Error {
    case cannotCreateFormat
    case cannotCreateBuffer
}
