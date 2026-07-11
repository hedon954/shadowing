import Accelerate
@preconcurrency import AVFoundation
import CoreMedia
import Foundation

enum WaveformGenerationError: Error, Equatable, LocalizedError, Sendable {
    case noAudioTrack
    case invalidResolution(Int)
    case cannotCreateReader(String)
    case cannotStartReader(String)
    case unsupportedPCMBuffer
    case readerFailed(String)

    var errorDescription: String? {
        switch self {
        case .noAudioTrack:
            "The source does not contain an audio track."
        case let .invalidResolution(value):
            "Waveform resolution must be greater than zero, not \(value)."
        case let .cannotCreateReader(reason):
            "Cannot create the waveform reader: \(reason)"
        case let .cannotStartReader(reason):
            "Cannot start the waveform reader: \(reason)"
        case .unsupportedPCMBuffer:
            "The decoded audio buffer is not supported for waveform generation."
        case let .readerFailed(reason):
            "Waveform decoding failed: \(reason)"
        }
    }
}

struct WaveformPeakGenerator: Sendable {
    static let defaultFramesPerPeak = [256, 1024, 4096, 16384]

    func generate(
        from sourceURL: URL,
        framesPerPeak: [Int] = Self.defaultFramesPerPeak
    ) async throws -> WaveformData {
        for resolution in framesPerPeak where resolution <= 0 {
            throw WaveformGenerationError.invalidResolution(resolution)
        }
        let fingerprint = try SourceFingerprint.make(for: sourceURL)
        let task = Task.detached(priority: .utility) {
            try await Self.decode(
                sourceURL: sourceURL,
                fingerprint: fingerprint,
                framesPerPeak: Array(Set(framesPerPeak)).sorted()
            )
        }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    private static func decode(
        sourceURL: URL,
        fingerprint: SourceFingerprint,
        framesPerPeak: [Int]
    ) async throws -> WaveformData {
        let asset = AVURLAsset(url: sourceURL)
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        guard let track = tracks.first else {
            throw WaveformGenerationError.noAudioTrack
        }
        let (reader, output) = try makeReader(asset: asset, track: track)

        var accumulators = framesPerPeak.map(PeakAccumulator.init)
        var sampleRate: Double?
        var decodedFrames: Int64 = 0

        do {
            while let sampleBuffer = output.copyNextSampleBuffer() {
                try Task.checkCancellation()
                let bufferSampleRate = try process(
                    sampleBuffer,
                    accumulators: &accumulators
                )
                if sampleRate == nil {
                    sampleRate = bufferSampleRate
                }
                decodedFrames += Int64(CMSampleBufferGetNumSamples(sampleBuffer))
            }
            try Task.checkCancellation()
        } catch {
            reader.cancelReading()
            throw error
        }

        guard reader.status == .completed else {
            throw WaveformGenerationError.readerFailed(
                reader.error?.localizedDescription ?? "Reader ended with status \(reader.status.rawValue)."
            )
        }
        guard let sampleRate, sampleRate > 0 else {
            throw WaveformGenerationError.unsupportedPCMBuffer
        }

        return WaveformData(
            fingerprint: fingerprint,
            duration: Double(decodedFrames) / sampleRate,
            sampleRate: sampleRate,
            levels: accumulators.map { accumulator in
                WaveformEnvelopeLevel(
                    framesPerPoint: accumulator.framesPerPeak,
                    points: accumulator.finishedPoints()
                )
            }
        )
    }

    private static func makeReader(
        asset: AVAsset,
        track: AVAssetTrack
    ) throws -> (AVAssetReader, AVAssetReaderTrackOutput) {
        let reader: AVAssetReader
        do {
            reader = try AVAssetReader(asset: asset)
        } catch {
            throw WaveformGenerationError.cannotCreateReader(error.localizedDescription)
        }

        let output = AVAssetReaderTrackOutput(
            track: track,
            outputSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVLinearPCMBitDepthKey: 32,
                AVLinearPCMIsFloatKey: true,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: false,
                AVNumberOfChannelsKey: 1
            ]
        )
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else {
            throw WaveformGenerationError.cannotCreateReader(
                "The asset reader rejected the PCM output."
            )
        }
        reader.add(output)
        guard reader.startReading() else {
            throw WaveformGenerationError.cannotStartReader(
                reader.error?.localizedDescription ?? "Unknown reader error."
            )
        }
        return (reader, output)
    }

    private static func process(
        _ sampleBuffer: CMSampleBuffer,
        accumulators: inout [PeakAccumulator]
    ) throws -> Double {
        guard let description = CMSampleBufferGetFormatDescription(sampleBuffer),
              let streamDescription = CMAudioFormatDescriptionGetStreamBasicDescription(
                  description
              )
        else {
            throw WaveformGenerationError.unsupportedPCMBuffer
        }

        var retainedBlockBuffer: CMBlockBuffer?
        var audioBufferList = AudioBufferList(
            mNumberBuffers: 1,
            mBuffers: AudioBuffer(mNumberChannels: 0, mDataByteSize: 0, mData: nil)
        )
        let status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: nil,
            bufferListOut: &audioBufferList,
            bufferListSize: MemoryLayout<AudioBufferList>.size,
            blockBufferAllocator: nil,
            blockBufferMemoryAllocator: nil,
            flags: UInt32(kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment),
            blockBufferOut: &retainedBlockBuffer
        )
        guard status == noErr,
              audioBufferList.mNumberBuffers == 1,
              let data = audioBufferList.mBuffers.mData
        else {
            throw WaveformGenerationError.unsupportedPCMBuffer
        }

        let channelCount = max(Int(audioBufferList.mBuffers.mNumberChannels), 1)
        let availableSamples = Int(audioBufferList.mBuffers.mDataByteSize) /
            MemoryLayout<Float>.stride
        let frameCount = min(
            CMSampleBufferGetNumSamples(sampleBuffer),
            availableSamples / channelCount
        )
        let samples = data.assumingMemoryBound(to: Float.self)
        for index in accumulators.indices {
            accumulators[index].append(
                samples: samples,
                frameCount: frameCount,
                channelCount: channelCount
            )
        }
        return streamDescription.pointee.mSampleRate
    }
}

private struct PeakAccumulator {
    let framesPerPeak: Int
    private var points: [WaveformEnvelopePoint] = []
    private var pendingFrameCount = 0
    private var pendingMinimum: Float = 1
    private var pendingMaximum: Float = -1

    init(framesPerPeak: Int) {
        self.framesPerPeak = framesPerPeak
    }

    mutating func append(
        samples: UnsafePointer<Float>,
        frameCount: Int,
        channelCount: Int
    ) {
        var frameOffset = 0
        while frameOffset < frameCount {
            let acceptedFrames = min(
                framesPerPeak - pendingFrameCount,
                frameCount - frameOffset
            )
            let sampleOffset = frameOffset * channelCount
            let sampleCount = acceptedFrames * channelCount
            var segmentMinimum: Float = 0
            var segmentMaximum: Float = 0
            vDSP_minv(
                samples.advanced(by: sampleOffset),
                1,
                &segmentMinimum,
                vDSP_Length(sampleCount)
            )
            vDSP_maxv(
                samples.advanced(by: sampleOffset),
                1,
                &segmentMaximum,
                vDSP_Length(sampleCount)
            )
            pendingMinimum = min(pendingMinimum, segmentMinimum)
            pendingMaximum = max(pendingMaximum, segmentMaximum)
            pendingFrameCount += acceptedFrames
            frameOffset += acceptedFrames

            if pendingFrameCount == framesPerPeak {
                points.append(
                    WaveformEnvelopePoint(
                        minimum: pendingMinimum,
                        maximum: pendingMaximum
                    )
                )
                pendingFrameCount = 0
                pendingMinimum = 1
                pendingMaximum = -1
            }
        }
    }

    func finishedPoints() -> [WaveformEnvelopePoint] {
        guard pendingFrameCount > 0 else {
            return points
        }
        return points + [
            WaveformEnvelopePoint(
                minimum: pendingMinimum,
                maximum: pendingMaximum
            )
        ]
    }
}
