import Foundation

enum AudioTimingError: Error, Equatable, LocalizedError, Sendable {
    case invalidSampleRate
    case invalidTime
    case invalidPlaybackRate
    case invalidFrameRange
    case frameOverflow

    var errorDescription: String? {
        switch self {
        case .invalidSampleRate:
            "The audio sample rate must be finite and greater than zero."
        case .invalidTime:
            "The audio time must be finite and greater than or equal to zero."
        case .invalidPlaybackRate:
            "The playback rate must be finite and greater than zero."
        case .invalidFrameRange:
            "The audio frame range is invalid."
        case .frameOverflow:
            "The audio time cannot be represented as a frame position."
        }
    }
}

struct AudioFrameTimeConverter: Equatable, Sendable {
    let sampleRate: Double

    init(sampleRate: Double) throws {
        guard sampleRate.isFinite, sampleRate > 0 else {
            throw AudioTimingError.invalidSampleRate
        }
        self.sampleRate = sampleRate
    }

    func frame(at time: TimeInterval) throws -> Int64 {
        guard time.isFinite, time >= 0 else {
            throw AudioTimingError.invalidTime
        }
        let value = time * sampleRate
        guard value <= Double(Int64.max) else {
            throw AudioTimingError.frameOverflow
        }
        return Int64(value.rounded(.toNearestOrAwayFromZero))
    }

    func time(at frame: Int64) throws -> TimeInterval {
        guard frame >= 0 else {
            throw AudioTimingError.invalidFrameRange
        }
        return Double(frame) / sampleRate
    }
}

struct AudioSchedulePlan: Equatable, Sendable {
    let sourceStartFrame: Int64
    let sourceFrameCount: Int64
    let outputFrameCount: Int64
    let playbackRate: Double
}

struct AudioSegment: Equatable, Sendable {
    let startFrame: Int64
    let frameCount: Int64
}

struct PlaybackSegmentPlan: Equatable, Sendable {
    let initial: AudioSegment
    let repeated: AudioSegment?
}

struct PlaybackSegmentPlanner: Sendable {
    static func plan(
        from requestedFrame: Int64,
        sourceFrameCount: Int64,
        loopScheduler: RegionLoopScheduler?
    ) throws -> PlaybackSegmentPlan {
        guard sourceFrameCount > 0 else {
            throw AudioTimingError.invalidFrameRange
        }

        guard let loopScheduler else {
            let startFrame = min(max(requestedFrame, 0), sourceFrameCount - 1)
            return PlaybackSegmentPlan(
                initial: AudioSegment(
                    startFrame: startFrame,
                    frameCount: sourceFrameCount - startFrame
                ),
                repeated: nil
            )
        }

        guard loopScheduler.regionEndFrame <= sourceFrameCount else {
            throw AudioTimingError.invalidFrameRange
        }
        let startFrame = loopScheduler.contains(requestedFrame)
            ? requestedFrame
            : loopScheduler.regionStartFrame
        return PlaybackSegmentPlan(
            initial: AudioSegment(
                startFrame: startFrame,
                frameCount: loopScheduler.regionEndFrame - startFrame
            ),
            repeated: AudioSegment(
                startFrame: loopScheduler.regionStartFrame,
                frameCount: loopScheduler.regionFrameCount
            )
        )
    }
}

struct RegionLoopScheduler: Equatable, Sendable {
    let regionStartFrame: Int64
    let regionEndFrame: Int64
    let sourceSampleRate: Double
    let playbackRate: Double

    var regionFrameCount: Int64 {
        regionEndFrame - regionStartFrame
    }

    init(
        regionStartFrame: Int64,
        regionEndFrame: Int64,
        sourceSampleRate: Double,
        playbackRate: Double
    ) throws {
        guard regionStartFrame >= 0, regionEndFrame > regionStartFrame else {
            throw AudioTimingError.invalidFrameRange
        }
        guard sourceSampleRate.isFinite, sourceSampleRate > 0 else {
            throw AudioTimingError.invalidSampleRate
        }
        guard playbackRate.isFinite, playbackRate > 0 else {
            throw AudioTimingError.invalidPlaybackRate
        }

        self.regionStartFrame = regionStartFrame
        self.regionEndFrame = regionEndFrame
        self.sourceSampleRate = sourceSampleRate
        self.playbackRate = playbackRate
    }

    init(
        region: PracticeRegion,
        converter: AudioFrameTimeConverter,
        playbackRate: Double
    ) throws {
        try self.init(
            regionStartFrame: converter.frame(at: region.start),
            regionEndFrame: converter.frame(at: region.end),
            sourceSampleRate: converter.sampleRate,
            playbackRate: playbackRate
        )
    }

    func sourceBoundaryFrame(afterLoop loopIndex: Int) throws -> Int64 {
        guard loopIndex >= 0 else {
            throw AudioTimingError.invalidFrameRange
        }
        let (offset, overflowed) = regionFrameCount.multipliedReportingOverflow(
            by: Int64(loopIndex)
        )
        let (boundary, addedOverflow) = regionStartFrame.addingReportingOverflow(offset)
        guard !overflowed, !addedOverflow else {
            throw AudioTimingError.frameOverflow
        }
        return boundary
    }

    func outputBoundaryFrame(
        afterLoop loopIndex: Int,
        outputSampleRate: Double
    ) throws -> Int64 {
        guard outputSampleRate.isFinite, outputSampleRate > 0 else {
            throw AudioTimingError.invalidSampleRate
        }
        let sourceBoundary = try sourceBoundaryFrame(afterLoop: loopIndex)
        let sourceOffset = sourceBoundary - regionStartFrame
        return try outputFrames(
            forSourceFrames: sourceOffset,
            outputSampleRate: outputSampleRate,
            rate: playbackRate
        )
    }

    func schedule(
        from sourceFrame: Int64,
        outputSampleRate: Double,
        rate newRate: Double? = nil
    ) throws -> AudioSchedulePlan {
        guard sourceFrame >= regionStartFrame, sourceFrame < regionEndFrame else {
            throw AudioTimingError.invalidFrameRange
        }
        let rate = newRate ?? playbackRate
        let sourceFrameCount = regionEndFrame - sourceFrame
        return try AudioSchedulePlan(
            sourceStartFrame: sourceFrame,
            sourceFrameCount: sourceFrameCount,
            outputFrameCount: outputFrames(
                forSourceFrames: sourceFrameCount,
                outputSampleRate: outputSampleRate,
                rate: rate
            ),
            playbackRate: rate
        )
    }

    func contains(_ sourceFrame: Int64) -> Bool {
        regionStartFrame ..< regionEndFrame ~= sourceFrame
    }

    private func outputFrames(
        forSourceFrames sourceFrames: Int64,
        outputSampleRate: Double,
        rate: Double
    ) throws -> Int64 {
        guard sourceFrames >= 0 else {
            throw AudioTimingError.invalidFrameRange
        }
        guard rate.isFinite, rate > 0 else {
            throw AudioTimingError.invalidPlaybackRate
        }
        let value = Double(sourceFrames) * outputSampleRate / sourceSampleRate / rate
        guard value <= Double(Int64.max) else {
            throw AudioTimingError.frameOverflow
        }
        return Int64(value.rounded(.toNearestOrAwayFromZero))
    }
}
