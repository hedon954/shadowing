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
    /// Merges previous take audio with a new recording so only the overlapping
    /// source range is replaced. Writes a contiguous CAF to `outputURL`.
    static func merge(
        existingURL: URL,
        newRecordingURL: URL,
        plan: TakeOverwritePlan,
        outputURL: URL
    ) throws {
        guard plan.resultDuration > 0, plan.insertedDuration > 0 else {
            throw TakeAudioSplicerError.invalidPlan
        }

        let existing: AVAudioFile
        do {
            existing = try AVAudioFile(forReading: existingURL)
        } catch {
            throw TakeAudioSplicerError.cannotOpenExisting(error.localizedDescription)
        }
        let incoming: AVAudioFile
        do {
            incoming = try AVAudioFile(forReading: newRecordingURL)
        } catch {
            throw TakeAudioSplicerError.cannotOpenNewRecording(error.localizedDescription)
        }

        let format = incoming.processingFormat
        if FileManager.default.fileExists(atPath: outputURL.path) {
            try FileManager.default.removeItem(at: outputURL)
        }
        let output: AVAudioFile
        do {
            output = try AVAudioFile(
                forWriting: outputURL,
                settings: format.settings,
                commonFormat: format.commonFormat,
                interleaved: format.isInterleaved
            )
        } catch {
            throw TakeAudioSplicerError.cannotCreateOutput(error.localizedDescription)
        }

        if plan.headDuration > 0 {
            try copy(
                from: existing,
                localStart: 0,
                duration: plan.headDuration,
                to: output,
                preferredFormat: format
            )
        }
        try copy(
            from: incoming,
            localStart: 0,
            duration: plan.insertedDuration,
            to: output,
            preferredFormat: format
        )
        if plan.tailDuration > 0 {
            try copy(
                from: existing,
                localStart: plan.previousTailLocalStart,
                duration: plan.tailDuration,
                to: output,
                preferredFormat: format
            )
        }
    }

    private static func copy(
        from source: AVAudioFile,
        localStart: TimeInterval,
        duration: TimeInterval,
        to destination: AVAudioFile,
        preferredFormat: AVAudioFormat
    ) throws {
        let sampleRate = source.processingFormat.sampleRate
        guard sampleRate > 0, duration > 0 else {
            return
        }
        let startFrame = AVAudioFramePosition(
            max((localStart * sampleRate).rounded(.towardZero), 0)
        )
        let frameCount = AVAudioFrameCount(
            max((duration * sampleRate).rounded(.towardZero), 0)
        )
        guard frameCount > 0 else {
            return
        }
        source.framePosition = min(startFrame, source.length)

        let bufferCapacity = min(frameCount, 8192)
        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: source.processingFormat,
            frameCapacity: bufferCapacity
        ) else {
            throw TakeAudioSplicerError.readFailed("Unable to allocate PCM buffer.")
        }

        var remaining = frameCount
        while remaining > 0 {
            let request = min(remaining, bufferCapacity)
            do {
                try source.read(into: buffer, frameCount: request)
            } catch {
                throw TakeAudioSplicerError.readFailed(error.localizedDescription)
            }
            guard buffer.frameLength > 0 else {
                break
            }
            let toWrite: AVAudioPCMBuffer
            if buffer.format == preferredFormat {
                toWrite = buffer
            } else {
                guard let converted = convert(buffer, to: preferredFormat) else {
                    throw TakeAudioSplicerError.readFailed("Unable to convert take audio format.")
                }
                toWrite = converted
            }
            do {
                try destination.write(from: toWrite)
            } catch {
                throw TakeAudioSplicerError.writeFailed(error.localizedDescription)
            }
            remaining -= buffer.frameLength
        }
    }

    private static func convert(
        _ buffer: AVAudioPCMBuffer,
        to format: AVAudioFormat
    ) -> AVAudioPCMBuffer? {
        guard let converter = AVAudioConverter(from: buffer.format, to: format),
              let output = AVAudioPCMBuffer(
                  pcmFormat: format,
                  frameCapacity: buffer.frameLength
              )
        else {
            return nil
        }
        var error: NSError?
        let inputBlock: AVAudioConverterInputBlock = { _, outStatus in
            outStatus.pointee = .haveData
            return buffer
        }
        converter.convert(to: output, error: &error, withInputFrom: inputBlock)
        if error != nil {
            return nil
        }
        return output
    }
}
