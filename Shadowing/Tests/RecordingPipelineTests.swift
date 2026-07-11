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
        let pipeline = try RecordingPipeline(
            destinationURL: destination,
            format: format,
            framesPerEnvelopePoint: 1024
        )
        let updateTask = Task {
            var points: [TimedWaveformEnvelopePoint] = []
            for await update in pipeline.updateStream {
                points.append(contentsOf: update.points)
            }
            return points
        }

        for _ in 0 ..< 4 {
            try pipeline.capture(
                makeFloatBuffer(
                    format: format,
                    frameCount: 1024,
                    amplitude: 0.6
                )
            )
        }

        let result = try await pipeline.finish()
        let points = await updateTask.value
        XCTAssertEqual(result.duration, 4096 / 48000, accuracy: 1 / 48000)
        XCTAssertEqual(result.droppedBufferCount, 0)
        XCTAssertEqual(points.count, 4)
        XCTAssertTrue(
            points.allSatisfy {
                abs($0.envelope.minimum + 0.6) < 0.001 &&
                    abs($0.envelope.maximum - 0.6) < 0.001
            }
        )
        try assertPlayableRecording(at: destination)
    }

    func testPipelinePublishesPeaksForInt16Input() async throws {
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
        let destination = directory.appendingPathComponent("recording-int16.caf")
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: 48000,
            channels: 1,
            interleaved: false
        ) else {
            return XCTFail("Could not create Int16 test format")
        }
        let pipeline = try RecordingPipeline(
            destinationURL: destination,
            format: format,
            framesPerEnvelopePoint: 1024
        )
        let updateTask = Task {
            var points: [TimedWaveformEnvelopePoint] = []
            for await update in pipeline.updateStream {
                points.append(contentsOf: update.points)
            }
            return points
        }

        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: 1024
        ), let samples = buffer.int16ChannelData?[0]
        else {
            return XCTFail("Could not create Int16 test buffer")
        }
        buffer.frameLength = 1024
        let amplitude = Int16(Int16.max / 2)
        for index in 0 ..< 1024 {
            samples[index] = index.isMultiple(of: 2) ? amplitude : -amplitude
        }
        pipeline.capture(buffer)

        let result = try await pipeline.finish()
        let points = await updateTask.value
        XCTAssertEqual(result.droppedBufferCount, 0)
        XCTAssertEqual(points.count, 1)
        XCTAssertEqual(points[0].envelope.minimum, -0.5, accuracy: 0.02)
        XCTAssertEqual(points[0].envelope.maximum, 0.5, accuracy: 0.02)
    }

    func testPipelinePublishesEnvelopeForInt32Input() async throws {
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
        let destination = directory.appendingPathComponent("recording-int32.caf")
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatInt32,
            sampleRate: 48000,
            channels: 1,
            interleaved: false
        ) else {
            return XCTFail("Could not create Int32 test format")
        }
        let pipeline = try RecordingPipeline(
            destinationURL: destination,
            format: format,
            framesPerEnvelopePoint: 512
        )
        let updateTask = Task {
            var points: [TimedWaveformEnvelopePoint] = []
            for await update in pipeline.updateStream {
                points.append(contentsOf: update.points)
            }
            return points
        }
        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: 512
        ), let samples = buffer.int32ChannelData?[0]
        else {
            return XCTFail("Could not create Int32 test buffer")
        }
        buffer.frameLength = 512
        let amplitude = Int32(Int32.max / 4)
        for index in 0 ..< 512 {
            samples[index] = index.isMultiple(of: 2) ? amplitude : -amplitude
        }
        pipeline.capture(buffer)

        _ = try await pipeline.finish()
        let points = await updateTask.value

        XCTAssertEqual(points.count, 1)
        XCTAssertEqual(points[0].envelope.minimum, -0.25, accuracy: 0.02)
        XCTAssertEqual(points[0].envelope.maximum, 0.25, accuracy: 0.02)
    }

    func testPipelineStopsAtMaximumCapturedFrameCount() async throws {
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
        let destination = directory.appendingPathComponent("recording-limited.caf")
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 48000,
            channels: 1,
            interleaved: false
        ) else {
            return XCTFail("Could not create test format")
        }
        let maximumFrames = 512
        let pipeline = try RecordingPipeline(
            destinationURL: destination,
            format: format,
            framesPerEnvelopePoint: 256,
            maximumDuration: Double(maximumFrames) / format.sampleRate
        )
        let updateTask = Task {
            var updates: [RecordingPipelineUpdate] = []
            for await update in pipeline.updateStream {
                updates.append(update)
            }
            return updates
        }
        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: 1024
        ), let samples = buffer.floatChannelData?[0]
        else {
            return XCTFail("Could not create test buffer")
        }
        buffer.frameLength = 1024
        for index in 0 ..< 1024 {
            samples[index] = index.isMultiple(of: 2) ? 0.7 : -0.7
        }
        pipeline.capture(buffer)

        let result = try await pipeline.finish()
        let updates = await updateTask.value

        XCTAssertEqual(result.duration, Double(maximumFrames) / 48000, accuracy: 1 / 48000)
        XCTAssertEqual(updates.last?.reachedLimit, true)
        XCTAssertEqual(updates.flatMap(\.points).count, 2)
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

    private func makeFloatBuffer(
        format: AVAudioFormat,
        frameCount: Int,
        amplitude: Float
    ) throws -> AVAudioPCMBuffer {
        let buffer = try XCTUnwrap(
            AVAudioPCMBuffer(
                pcmFormat: format,
                frameCapacity: AVAudioFrameCount(frameCount)
            )
        )
        let samples = try XCTUnwrap(buffer.floatChannelData?[0])
        buffer.frameLength = AVAudioFrameCount(frameCount)
        for index in 0 ..< frameCount {
            samples[index] = index.isMultiple(of: 2) ? amplitude : -amplitude
        }
        return buffer
    }

    private func assertPlayableRecording(at destination: URL) throws {
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
}
