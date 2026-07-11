import Accelerate
@preconcurrency import AVFoundation
import Foundation

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

final class RecordingPipeline: @unchecked Sendable {
    let peakStream: AsyncStream<Float>

    private let destinationURL: URL
    private let sampleRate: Double
    private let packetContinuation: AsyncStream<OwnedAudioBuffer>.Continuation
    private let peakContinuation: AsyncStream<Float>.Continuation
    private let writerTask: Task<Int64, Error>
    private let droppedBufferCount = OSAllocatedUnfairLock(initialState: 0)

    init(destinationURL: URL, format: AVAudioFormat, queueCapacity: Int = 8) throws {
        self.destinationURL = destinationURL
        sampleRate = format.sampleRate

        let writer: OwnedAudioFile
        do {
            writer = try OwnedAudioFile(
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

        let packetPair = AsyncStream<OwnedAudioBuffer>.makeStream(
            bufferingPolicy: .bufferingNewest(queueCapacity)
        )
        packetContinuation = packetPair.continuation
        let peakPair = AsyncStream<Float>.makeStream(
            bufferingPolicy: .bufferingNewest(64)
        )
        peakStream = peakPair.stream
        peakContinuation = peakPair.continuation

        writerTask = Task.detached(priority: .userInitiated) {
            var writtenFrames: Int64 = 0
            do {
                for await packet in packetPair.stream {
                    try writer.file.write(from: packet.buffer)
                    writtenFrames += Int64(packet.buffer.frameLength)
                }
                return writtenFrames
            } catch {
                throw RecordingPipelineError.writerFailed(
                    path: destinationURL.path,
                    reason: error.localizedDescription
                )
            }
        }
    }

    deinit {
        packetContinuation.finish()
        peakContinuation.finish()
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
        peakContinuation.yield(packet.peak)
    }

    func finish() async throws -> RecordingPipelineResult {
        packetContinuation.finish()
        peakContinuation.finish()
        let frameCount = try await writerTask.value
        return RecordingPipelineResult(
            url: destinationURL,
            duration: Double(frameCount) / sampleRate,
            droppedBufferCount: droppedBufferCount.withLock { $0 }
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
    // The copy owns its PCM storage and is immutable after the input callback returns.
    let buffer: AVAudioPCMBuffer
    let peak: Float

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

        var measuredPeak: Float = 0
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

            let sampleCount = byteCount / MemoryLayout<Float>.stride
            guard sampleCount > 0 else {
                continue
            }
            var bufferPeak: Float = 0
            vDSP_maxmgv(
                sourceData.assumingMemoryBound(to: Float.self),
                1,
                &bufferPeak,
                vDSP_Length(sampleCount)
            )
            measuredPeak = max(measuredPeak, bufferPeak)
        }

        buffer = copy
        peak = min(max(measuredPeak, 0), 1)
    }
}
