@preconcurrency import AVFoundation
import Foundation

enum TakeAudioSplicerError: Error, LocalizedError, Sendable {
    case cannotOpenExisting(String)
    case cannotOpenNewRecording(String)
    case cannotCreateOutput(String)
    case readFailed(String)
    case writeFailed(String)
    case invalidPlan

    var errorDescription: String? {
        switch self {
        case let .cannotOpenExisting(reason):
            "Cannot open the existing take for overwrite: \(reason)"
        case let .cannotOpenNewRecording(reason):
            "Cannot open the new recording for overwrite: \(reason)"
        case let .cannotCreateOutput(reason):
            "Cannot create the merged take file: \(reason)"
        case let .readFailed(reason):
            "Cannot read audio while merging takes: \(reason)"
        case let .writeFailed(reason):
            "Cannot write the merged take: \(reason)"
        case .invalidPlan:
            "The overwrite merge plan is invalid."
        }
    }
}

enum TakeAudioSplicer {
    /// Merges previous take audio with a new recording on the Original timeline.
    /// Non-overlapping gaps are filled with silence so local file time stays aligned
    /// with source time (`local 0` → `plan.resultStart`).
    static func merge(
        existingURL: URL,
        newRecordingURL: URL,
        plan: TakeOverwritePlan,
        outputURL: URL
    ) throws {
        guard plan.resultDuration > 0, plan.insertedDuration > 0, !plan.segments.isEmpty else {
            throw TakeAudioSplicerError.invalidPlan
        }

        let existing = try openForReading(existingURL, as: .existing)
        let incoming = try openForReading(newRecordingURL, as: .incoming)
        let format = incoming.processingFormat
        let output = try openForWriting(outputURL, format: format)

        for segment in plan.segments {
            try write(segment, existing: existing, incoming: incoming, to: output, format: format)
        }
    }

    private enum OpenRole {
        case existing
        case incoming
    }

    private static func openForReading(_ url: URL, as role: OpenRole) throws -> AVAudioFile {
        do {
            return try AVAudioFile(forReading: url)
        } catch {
            switch role {
            case .existing:
                throw TakeAudioSplicerError.cannotOpenExisting(error.localizedDescription)
            case .incoming:
                throw TakeAudioSplicerError.cannotOpenNewRecording(error.localizedDescription)
            }
        }
    }

    private static func openForWriting(_ url: URL, format: AVAudioFormat) throws -> AVAudioFile {
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
        do {
            return try AVAudioFile(
                forWriting: url,
                settings: format.settings,
                commonFormat: format.commonFormat,
                interleaved: format.isInterleaved
            )
        } catch {
            throw TakeAudioSplicerError.cannotCreateOutput(error.localizedDescription)
        }
    }

    private static func write(
        _ segment: TakeOverwriteSegment,
        existing: AVAudioFile,
        incoming: AVAudioFile,
        to output: AVAudioFile,
        format: AVAudioFormat
    ) throws {
        switch segment.source {
        case let .previous(localStart):
            try copyAndPad(
                from: existing,
                localStart: localStart,
                duration: segment.duration,
                to: output,
                format: format
            )
        case let .incoming(localStart):
            try copyAndPad(
                from: incoming,
                localStart: localStart,
                duration: segment.duration,
                to: output,
                format: format
            )
        case .silence:
            try writeSilence(duration: segment.duration, to: output, format: format)
        }
    }

    private static func copyAndPad(
        from source: AVAudioFile,
        localStart: TimeInterval,
        duration: TimeInterval,
        to destination: AVAudioFile,
        format: AVAudioFormat
    ) throws {
        let written = try copy(
            from: source,
            localStart: localStart,
            duration: duration,
            to: destination,
            preferredFormat: format
        )
        let remaining = duration - written
        guard remaining > 0.000_001 else {
            return
        }
        try writeSilence(duration: remaining, to: destination, format: format)
    }

    private static func writeSilence(
        duration: TimeInterval,
        to destination: AVAudioFile,
        format: AVAudioFormat
    ) throws {
        let sampleRate = format.sampleRate
        guard sampleRate > 0, duration > 0 else {
            return
        }
        var remaining = AVAudioFrameCount(
            max((duration * sampleRate).rounded(.towardZero), 0)
        )
        guard remaining > 0 else {
            return
        }
        let capacity = min(remaining, 8192)
        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: capacity
        ) else {
            throw TakeAudioSplicerError.writeFailed("Unable to allocate silence buffer.")
        }
        while remaining > 0 {
            let frameCount = min(remaining, capacity)
            buffer.frameLength = frameCount
            clear(buffer)
            do {
                try destination.write(from: buffer)
            } catch {
                throw TakeAudioSplicerError.writeFailed(error.localizedDescription)
            }
            remaining -= frameCount
        }
    }

    private static func clear(_ buffer: AVAudioPCMBuffer) {
        let frameLength = Int(buffer.frameLength)
        guard frameLength > 0 else {
            return
        }
        let channelCount = Int(buffer.format.channelCount)
        if let channels = buffer.floatChannelData {
            zero(channels, channelCount: channelCount, frameLength: frameLength)
        } else if let channels = buffer.int16ChannelData {
            zero(channels, channelCount: channelCount, frameLength: frameLength)
        } else if let channels = buffer.int32ChannelData {
            zero(channels, channelCount: channelCount, frameLength: frameLength)
        }
    }

    private static func zero(
        _ channels: UnsafePointer<UnsafeMutablePointer<some ExpressibleByIntegerLiteral>>,
        channelCount: Int,
        frameLength: Int
    ) {
        for channel in 0 ..< channelCount {
            channels[channel].update(repeating: 0, count: frameLength)
        }
    }

    @discardableResult
    private static func copy(
        from source: AVAudioFile,
        localStart: TimeInterval,
        duration: TimeInterval,
        to destination: AVAudioFile,
        preferredFormat: AVAudioFormat
    ) throws -> TimeInterval {
        guard let frameCount = readableFrameCount(
            from: source,
            localStart: localStart,
            duration: duration
        ) else {
            return 0
        }
        source.framePosition = AVAudioFramePosition(
            max((localStart * source.processingFormat.sampleRate).rounded(.towardZero), 0)
        )
        let writtenDestinationFrames = try transfer(
            from: source,
            frameCount: frameCount,
            to: destination,
            preferredFormat: preferredFormat
        )
        let destinationRate = preferredFormat.sampleRate
        guard destinationRate > 0 else {
            return 0
        }
        return TimeInterval(writtenDestinationFrames) / destinationRate
    }

    private static func readableFrameCount(
        from source: AVAudioFile,
        localStart: TimeInterval,
        duration: TimeInterval
    ) -> AVAudioFrameCount? {
        let sampleRate = source.processingFormat.sampleRate
        guard sampleRate > 0, duration > 0, source.length > 0 else {
            return nil
        }
        let startFrame = AVAudioFramePosition(
            max((localStart * sampleRate).rounded(.towardZero), 0)
        )
        guard startFrame < source.length else {
            return nil
        }
        let requestedFrames = AVAudioFrameCount(
            max((duration * sampleRate).rounded(.towardZero), 0)
        )
        let availableFrames = AVAudioFrameCount(source.length - startFrame)
        let frameCount = min(requestedFrames, availableFrames)
        return frameCount > 0 ? frameCount : nil
    }

    private static func transfer(
        from source: AVAudioFile,
        frameCount: AVAudioFrameCount,
        to destination: AVAudioFile,
        preferredFormat: AVAudioFormat
    ) throws -> AVAudioFrameCount {
        let bufferCapacity = min(frameCount, 8192)
        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: source.processingFormat,
            frameCapacity: bufferCapacity
        ) else {
            throw TakeAudioSplicerError.readFailed("Unable to allocate PCM buffer.")
        }

        var remaining = frameCount
        var writtenDestinationFrames: AVAudioFrameCount = 0
        while remaining > 0 {
            let availableNow = AVAudioFrameCount(max(source.length - source.framePosition, 0))
            guard availableNow > 0 else {
                break
            }
            let request = min(remaining, bufferCapacity, availableNow)
            do {
                try source.read(into: buffer, frameCount: request)
            } catch {
                throw TakeAudioSplicerError.readFailed(error.localizedDescription)
            }
            guard buffer.frameLength > 0 else {
                break
            }
            let toWrite: AVAudioPCMBuffer = if buffer.format == preferredFormat {
                buffer
            } else {
                try convert(buffer, to: preferredFormat)
            }
            do {
                try destination.write(from: toWrite)
            } catch {
                throw TakeAudioSplicerError.writeFailed(error.localizedDescription)
            }
            writtenDestinationFrames += toWrite.frameLength
            remaining -= buffer.frameLength
        }
        return writtenDestinationFrames
    }

    private static func convert(
        _ buffer: AVAudioPCMBuffer,
        to format: AVAudioFormat
    ) throws -> AVAudioPCMBuffer {
        guard let converter = AVAudioConverter(from: buffer.format, to: format) else {
            throw TakeAudioSplicerError.readFailed("Unable to create take audio converter.")
        }
        let ratio = format.sampleRate / max(buffer.format.sampleRate, 1)
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 32
        guard let output = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: max(capacity, 1)
        ) else {
            throw TakeAudioSplicerError.readFailed("Unable to allocate converted PCM buffer.")
        }

        final class InputState: @unchecked Sendable {
            var provided = false
        }
        let inputState = InputState()
        var error: NSError?
        let inputBlock: AVAudioConverterInputBlock = { _, outStatus in
            if inputState.provided {
                outStatus.pointee = .endOfStream
                return nil
            }
            inputState.provided = true
            outStatus.pointee = .haveData
            return buffer
        }
        let status = converter.convert(to: output, error: &error, withInputFrom: inputBlock)
        if let error {
            throw TakeAudioSplicerError.readFailed(error.localizedDescription)
        }
        guard status != .error, output.frameLength > 0 else {
            throw TakeAudioSplicerError.readFailed("Unable to convert take audio format.")
        }
        return output
    }
}
