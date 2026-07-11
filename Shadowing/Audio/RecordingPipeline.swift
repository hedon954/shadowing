@preconcurrency import AVFoundation
import Foundation
import os

enum RecordingPipelineError: Error, LocalizedError, Sendable {
    case cannotCopyInputBuffer
    case writerCreationFailed(path: String, reason: String)
    case writerFailed(path: String, reason: String)
    case bufferQueueOverrun

    var errorDescription: String? {
        switch self {
        case .cannotCopyInputBuffer:
            "The microphone buffer could not be copied for recording."
        case let .writerCreationFailed(path, reason):
            "Cannot create the temporary recording at \(path): \(reason)"
        case let .writerFailed(path, reason):
            "Cannot write the temporary recording at \(path): \(reason)"
        case .bufferQueueOverrun:
            "The recording writer could not keep up with the microphone input."
        }
    }
}

struct RecordingPipelineResult: Equatable, Sendable {
    let url: URL
    let duration: TimeInterval
    let droppedBufferCount: Int
}

struct RecordingPipelineUpdate: Equatable, Sendable {
    let elapsed: TimeInterval
    let points: [TimedWaveformEnvelopePoint]
    let reachedLimit: Bool
}

private struct RecordingWriterConfiguration: Sendable {
    let destinationURL: URL
    let sampleRate: Double
    let framesPerEnvelopePoint: Int
    let maximumFrameCount: Int64?
}

final class RecordingPipeline: @unchecked Sendable {
    let updateStream: AsyncStream<RecordingPipelineUpdate>

    private let destinationURL: URL
    private let sampleRate: Double
    private let packetContinuation: AsyncStream<OwnedAudioBuffer>.Continuation
    private let updateContinuation: AsyncStream<RecordingPipelineUpdate>.Continuation
    private let writerTask: Task<Int64, Error>
    private let droppedBufferCount = OSAllocatedUnfairLock(initialState: 0)

    init(
        destinationURL: URL,
        format: AVAudioFormat,
        queueCapacity: Int = 8,
        framesPerEnvelopePoint: Int = 256,
        maximumDuration: TimeInterval? = nil
    ) throws {
        self.destinationURL = destinationURL
        sampleRate = format.sampleRate

        let writer = try Self.makeWriter(destinationURL: destinationURL, format: format)
        let packetPair = AsyncStream<OwnedAudioBuffer>.makeStream(
            bufferingPolicy: .bufferingNewest(queueCapacity)
        )
        packetContinuation = packetPair.continuation
        let updatePair = AsyncStream<RecordingPipelineUpdate>.makeStream(
            bufferingPolicy: .bufferingNewest(64)
        )
        updateStream = updatePair.stream
        updateContinuation = updatePair.continuation
        let maximumFrameCount = maximumDuration.map {
            Int64(max(($0 * format.sampleRate).rounded(.toNearestOrAwayFromZero), 0))
        }
        writerTask = Self.makeWriterTask(
            writer: writer,
            packets: packetPair.stream,
            updates: updatePair.continuation,
            configuration: RecordingWriterConfiguration(
                destinationURL: destinationURL,
                sampleRate: format.sampleRate,
                framesPerEnvelopePoint: framesPerEnvelopePoint,
                maximumFrameCount: maximumFrameCount
            )
        )
    }

    deinit {
        packetContinuation.finish()
        updateContinuation.finish()
        writerTask.cancel()
    }

    func capture(_ inputBuffer: AVAudioPCMBuffer) {
        guard let packet = OwnedAudioBuffer(copying: inputBuffer) else {
            droppedBufferCount.withLock { $0 += 1 }
            return
        }
        let result = packetContinuation.yield(packet)
        if case .dropped = result {
            droppedBufferCount.withLock { $0 += 1 }
        }
    }

    func finish() async throws -> RecordingPipelineResult {
        packetContinuation.finish()
        let frameCount = try await writerTask.value
        updateContinuation.finish()
        return RecordingPipelineResult(
            url: destinationURL,
            duration: Double(frameCount) / sampleRate,
            droppedBufferCount: droppedBufferCount.withLock { $0 }
        )
    }

    private static func makeWriter(
        destinationURL: URL,
        format: AVAudioFormat
    ) throws -> OwnedAudioFile {
        do {
            return try OwnedAudioFile(
                file: AVAudioFile(
                    forWriting: destinationURL,
                    settings: format.settings,
                    commonFormat: format.commonFormat,
                    interleaved: format.isInterleaved
                )
            )
        } catch {
            throw RecordingPipelineError.writerCreationFailed(
                path: destinationURL.path,
                reason: error.localizedDescription
            )
        }
    }

    private static func makeWriterTask(
        writer: OwnedAudioFile,
        packets: AsyncStream<OwnedAudioBuffer>,
        updates: AsyncStream<RecordingPipelineUpdate>.Continuation,
        configuration: RecordingWriterConfiguration
    ) -> Task<Int64, Error> {
        Task.detached(priority: .userInitiated) {
            var writtenFrames: Int64 = 0
            var aggregator = LiveEnvelopeAccumulator(
                framesPerPoint: max(configuration.framesPerEnvelopePoint, 1),
                sampleRate: configuration.sampleRate
            )
            do {
                for await packet in packets {
                    let writableFrames = writableFrameCount(
                        buffer: packet.buffer,
                        writtenFrames: writtenFrames,
                        maximumFrameCount: configuration.maximumFrameCount
                    )
                    guard writableFrames > 0 else {
                        continue
                    }
                    packet.buffer.frameLength = AVAudioFrameCount(writableFrames)
                    let points = aggregator.consume(
                        packet.buffer,
                        startingFrame: writtenFrames
                    )
                    try writer.file.write(from: packet.buffer)
                    writtenFrames += writableFrames
                    updates.yield(
                        RecordingPipelineUpdate(
                            elapsed: Double(writtenFrames) / configuration.sampleRate,
                            points: points,
                            reachedLimit: configuration.maximumFrameCount.map {
                                writtenFrames >= $0
                            } ?? false
                        )
                    )
                }
                updates.finish()
                return writtenFrames
            } catch {
                updates.finish()
                throw RecordingPipelineError.writerFailed(
                    path: configuration.destinationURL.path,
                    reason: error.localizedDescription
                )
            }
        }
    }

    private static func writableFrameCount(
        buffer: AVAudioPCMBuffer,
        writtenFrames: Int64,
        maximumFrameCount: Int64?
    ) -> Int64 {
        guard let maximumFrameCount else {
            return Int64(buffer.frameLength)
        }
        guard writtenFrames < maximumFrameCount else {
            return 0
        }
        return min(
            Int64(buffer.frameLength),
            maximumFrameCount - writtenFrames
        )
    }
}

private final class OwnedAudioFile: @unchecked Sendable {
    /// The detached writer task is the sole accessor after initialization.
    let file: AVAudioFile

    init(file: AVAudioFile) {
        self.file = file
    }
}

private final class OwnedAudioBuffer: @unchecked Sendable {
    /// The copy owns its PCM storage and is immutable after the input callback returns.
    let buffer: AVAudioPCMBuffer

    init?(copying source: AVAudioPCMBuffer) {
        guard let copy = AVAudioPCMBuffer(
            pcmFormat: source.format,
            frameCapacity: source.frameLength
        ) else {
            return nil
        }
        copy.frameLength = source.frameLength

        let sourceBuffers = UnsafeMutableAudioBufferListPointer(
            UnsafeMutablePointer(mutating: source.audioBufferList)
        )
        let destinationBuffers = UnsafeMutableAudioBufferListPointer(
            copy.mutableAudioBufferList
        )
        guard sourceBuffers.count == destinationBuffers.count else {
            return nil
        }

        for index in sourceBuffers.indices {
            let sourceBuffer = sourceBuffers[index]
            var destinationBuffer = destinationBuffers[index]
            guard let sourceData = sourceBuffer.mData,
                  let destinationData = destinationBuffer.mData
            else {
                return nil
            }
            let byteCount = min(
                Int(sourceBuffer.mDataByteSize),
                Int(destinationBuffer.mDataByteSize)
            )
            memcpy(destinationData, sourceData, byteCount)
            destinationBuffer.mDataByteSize = UInt32(byteCount)
            destinationBuffers[index] = destinationBuffer
        }

        buffer = copy
    }
}

private struct LiveEnvelopeAccumulator {
    let framesPerPoint: Int
    let sampleRate: Double
    private var pendingFrameCount = 0
    private var pendingStartFrame: Int64 = 0
    private var pendingMinimum: Float = 1
    private var pendingMaximum: Float = -1

    init(framesPerPoint: Int, sampleRate: Double) {
        self.framesPerPoint = framesPerPoint
        self.sampleRate = sampleRate
    }

    mutating func consume(
        _ buffer: AVAudioPCMBuffer,
        startingFrame: Int64
    ) -> [TimedWaveformEnvelopePoint] {
        let frameLength = Int(buffer.frameLength)
        guard frameLength > 0 else {
            return []
        }
        var output: [TimedWaveformEnvelopePoint] = []
        output.reserveCapacity(frameLength / framesPerPoint + 1)

        for frame in 0 ..< frameLength {
            guard let extrema = extrema(in: buffer, frame: frame) else {
                continue
            }
            if pendingFrameCount == 0 {
                pendingStartFrame = startingFrame + Int64(frame)
            }
            pendingMinimum = min(pendingMinimum, extrema.minimum)
            pendingMaximum = max(pendingMaximum, extrema.maximum)
            pendingFrameCount += 1

            if pendingFrameCount == framesPerPoint {
                output.append(makePoint())
                resetPending()
            }
        }
        return output
    }

    private func extrema(
        in buffer: AVAudioPCMBuffer,
        frame: Int
    ) -> (minimum: Float, maximum: Float)? {
        let channelCount = Int(buffer.format.channelCount)
        guard channelCount > 0 else {
            return nil
        }
        let isInterleaved = buffer.format.isInterleaved

        switch buffer.format.commonFormat {
        case .pcmFormatFloat32:
            return floatExtrema(
                in: buffer,
                frame: frame,
                channelCount: channelCount,
                isInterleaved: isInterleaved
            )
        case .pcmFormatInt16:
            return int16Extrema(
                in: buffer,
                frame: frame,
                channelCount: channelCount,
                isInterleaved: isInterleaved
            )
        case .pcmFormatInt32:
            return int32Extrema(
                in: buffer,
                frame: frame,
                channelCount: channelCount,
                isInterleaved: isInterleaved
            )
        case .pcmFormatFloat64, .otherFormat:
            return nil
        @unknown default:
            return nil
        }
    }

    private func floatExtrema(
        in buffer: AVAudioPCMBuffer,
        frame: Int,
        channelCount: Int,
        isInterleaved: Bool
    ) -> (minimum: Float, maximum: Float)? {
        guard let channels = buffer.floatChannelData else {
            return nil
        }
        var result = (minimum: Float(1), maximum: Float(-1))
        for channel in 0 ..< channelCount {
            let sample = isInterleaved
                ? channels[0][frame * channelCount + channel]
                : channels[channel][frame]
            result.minimum = min(result.minimum, sample)
            result.maximum = max(result.maximum, sample)
        }
        return result
    }

    private func int16Extrema(
        in buffer: AVAudioPCMBuffer,
        frame: Int,
        channelCount: Int,
        isInterleaved: Bool
    ) -> (minimum: Float, maximum: Float)? {
        guard let channels = buffer.int16ChannelData else {
            return nil
        }
        var result = (minimum: Float(1), maximum: Float(-1))
        for channel in 0 ..< channelCount {
            let raw = isInterleaved
                ? channels[0][frame * channelCount + channel]
                : channels[channel][frame]
            let sample = Float(raw) / Float(Int16.max)
            result.minimum = min(result.minimum, sample)
            result.maximum = max(result.maximum, sample)
        }
        return result
    }

    private func int32Extrema(
        in buffer: AVAudioPCMBuffer,
        frame: Int,
        channelCount: Int,
        isInterleaved: Bool
    ) -> (minimum: Float, maximum: Float)? {
        guard let channels = buffer.int32ChannelData else {
            return nil
        }
        var result = (minimum: Float(1), maximum: Float(-1))
        for channel in 0 ..< channelCount {
            let raw = isInterleaved
                ? channels[0][frame * channelCount + channel]
                : channels[channel][frame]
            let sample = Float(raw) / Float(Int32.max)
            result.minimum = min(result.minimum, sample)
            result.maximum = max(result.maximum, sample)
        }
        return result
    }

    private func makePoint() -> TimedWaveformEnvelopePoint {
        let centerFrame = pendingStartFrame + Int64(pendingFrameCount / 2)
        return TimedWaveformEnvelopePoint(
            time: Double(centerFrame) / sampleRate,
            envelope: WaveformEnvelopePoint(
                minimum: pendingMinimum,
                maximum: pendingMaximum
            )
        )
    }

    private mutating func resetPending() {
        pendingFrameCount = 0
        pendingMinimum = 1
        pendingMaximum = -1
    }
}
