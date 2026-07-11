@preconcurrency import AVFoundation
@testable import Shadowing
import XCTest

final class RecordingPipelineTests: XCTestCase {
    func testPipelineWritesCopiedBuffersAndPublishesBoundedPeaks() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer {
            do {
                try FileManager.default.removeItem(at: directory)
            } catch {
                XCTFail("Could not remove recording fixture: \(error)")
            }
        }
        let destination = directory.appendingPathComponent("recording.caf")
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 48000,
            channels: 1,
            interleaved: false
        ) else {
            return XCTFail("Could not create test format")
        }
        let pipeline = try RecordingPipeline(destinationURL: destination, format: format)
        let peakTask = Task {
            var peaks: [Float] = []
            for await peak in pipeline.peakStream {
                peaks.append(peak)
            }
            return peaks
        }

        for _ in 0 ..< 4 {
            guard let buffer = AVAudioPCMBuffer(
                pcmFormat: format,
                frameCapacity: 1024
            ), let samples = buffer.floatChannelData?[0]
            else {
                return XCTFail("Could not create test buffer")
            }
            buffer.frameLength = 1024
            for index in 0 ..< 1024 {
                samples[index] = index.isMultiple(of: 2) ? 0.6 : -0.6
            }
            pipeline.capture(buffer)
        }

        let result = try await pipeline.finish()
        let peaks = await peakTask.value
        XCTAssertEqual(result.duration, 4096 / 48000, accuracy: 1 / 48000)
        XCTAssertEqual(result.droppedBufferCount, 0)
        XCTAssertEqual(peaks.count, 4)
        XCTAssertTrue(peaks.allSatisfy { abs($0 - 0.6) < 0.001 })
        XCTAssertGreaterThan(
            try destination.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0,
            0
        )
        XCTAssertNoThrow(
            try AVAudioRecordingFileValidator().validatePlayableRecording(
                at: destination
            )
        )
    }

    func testValidatorRejectsNonAudioTemporaryFile() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID()).caf")
        try Data([1, 2, 3]).write(to: url)
        defer {
            do {
                try FileManager.default.removeItem(at: url)
            } catch {
                XCTFail("Could not remove invalid recording fixture: \(error)")
            }
        }

        XCTAssertThrowsError(
            try AVAudioRecordingFileValidator().validatePlayableRecording(at: url)
        )
    }
}
