@preconcurrency import AVFoundation
import Foundation
import os

/// What a take needs from the microphone. The live one is `MicrophoneRecorder`; tests use fakes.
protocol MicrophoneCapturing: AnyObject {
    /// Format of the microphone buffers; throws when there is no usable input.
    func inputFormat() throws -> AVAudioFormat
    /// Installs the tap and starts the input. `onConfigurationChange` may be called on any thread.
    func start(
        onBuffer: @escaping @Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void,
        onConfigurationChange: @escaping @Sendable () -> Void
    ) throws
    /// Starts the input again after its configuration changed (device switch, sample rate).
    func restart() throws
    /// Removes the tap and stops the input. The recorder is not used again.
    func stop()
    var inputLatency: TimeInterval? { get }
}

/// One take's microphone: a throwaway `AVAudioEngine` that only ever uses its `inputNode`.
///
/// It never touches the engine's main mixer or output node, not even for a level meter: that
/// would give it an output, and macOS would switch it to an aggregate input/output device.
/// Playback stays on `PracticeAudioEngine`'s own engine, which never gets an input.
final class MicrophoneRecorder: MicrophoneCapturing, @unchecked Sendable {
    private let engine = AVAudioEngine()
    private var configurationToken: NSObjectProtocol?
    private var hasTap = false

    deinit {
        if let configurationToken {
            NotificationCenter.default.removeObserver(configurationToken)
        }
    }

    func inputFormat() throws -> AVAudioFormat {
        let input = engine.inputNode
        if let format = Self.usableFormat(of: input) {
            return format
        }
        // Some devices report their channels only once the input is prepared.
        engine.prepare()
        if let format = Self.usableFormat(of: input) {
            return format
        }
        throw PracticeAudioEngineError.inputUnavailable
    }

    func start(
        onBuffer: @escaping @Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void,
        onConfigurationChange: @escaping @Sendable () -> Void
    ) throws {
        engine.inputNode.installTap(onBus: 0, bufferSize: 4096, format: nil, block: Self.deliverable(onBuffer))
        hasTap = true
        configurationToken = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: nil
        ) { _ in
            onConfigurationChange()
        }
        try startEngine()
    }

    func restart() throws {
        engine.stop()
        try startEngine()
    }

    func stop() {
        if let configurationToken {
            NotificationCenter.default.removeObserver(configurationToken)
            self.configurationToken = nil
        }
        if hasTap {
            engine.inputNode.removeTap(onBus: 0)
            hasTap = false
        }
        engine.stop()
    }

    var inputLatency: TimeInterval? {
        engine.inputNode.presentationLatency
    }

    private func startEngine() throws {
        engine.prepare()
        do {
            try engine.start()
        } catch {
            throw PracticeAudioEngineError.audioEngineFailed(error.localizedDescription)
        }
    }

    /// Debug builds launched with `-ShadowingFakeNoMicBuffers` drop every microphone buffer, so
    /// the "No sound from the microphone" state can be reproduced and reviewed.
    private static func deliverable(
        _ onBuffer: @escaping @Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void
    ) -> @Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void {
        #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("-ShadowingFakeNoMicBuffers") {
                return { _, _ in }
            }
        #endif
        return onBuffer
    }

    private static func usableFormat(of input: AVAudioInputNode) -> AVAudioFormat? {
        [input.outputFormat(forBus: 0), input.inputFormat(forBus: 0)]
            .first { $0.channelCount > 0 && $0.sampleRate > 0 }
    }
}

/// Timeouts that keep a take from hanging when no audio arrives or the file can't be closed.
enum MicrophoneTakeTiming {
    /// No microphone buffer this long after R: the input isn't delivering audio.
    static let firstAudioTimeout: Duration = .seconds(2)
    /// Closing the take file takes longer than this: give up and report it.
    static let finishTimeout: Duration = .seconds(3)
}

/// One take on the microphone: the recorder feeding the file writer.
final class MicrophoneTake {
    let pipeline: RecordingPipeline
    private let recorder: any MicrophoneCapturing

    init(
        recorder: any MicrophoneCapturing,
        destinationURL: URL,
        maximumDuration: TimeInterval?,
        clock: RecordingAlignmentClock,
        onConfigurationChange: @escaping @Sendable () -> Void
    ) throws {
        self.recorder = recorder
        let pipeline = try RecordingPipeline(
            destinationURL: destinationURL,
            format: recorder.inputFormat(),
            maximumDuration: maximumDuration
        )
        self.pipeline = pipeline
        do {
            try recorder.start(
                onBuffer: { buffer, when in
                    clock.noteInput(when)
                    pipeline.capture(buffer)
                },
                onConfigurationChange: onConfigurationChange
            )
        } catch {
            recorder.stop()
            throw error
        }
    }

    var inputLatency: TimeInterval? {
        recorder.inputLatency
    }

    /// After the input's configuration changed: start it again. `false` when it can't be
    /// restarted (the device is gone); the caller then ends the take.
    func restartAfterConfigurationChange() -> Bool {
        do {
            try recorder.restart()
            return true
        } catch {
            return false
        }
    }

    func stopInput() {
        recorder.stop()
    }
}

/// Runs an operation but stops waiting for it after a timeout, even if it never returns or
/// ignores cancellation.
enum AsyncTimeout {
    struct Expired: Error, Equatable {}

    static func run<Value: Sendable>(
        _ timeout: Duration,
        operation: @escaping @Sendable () async throws -> Value
    ) async throws -> Value {
        let pending = OSAllocatedUnfairLock<CheckedContinuation<Value, Error>?>(initialState: nil)
        @Sendable func resume(_ result: Result<Value, Error>) {
            let continuation = pending.withLock { continuation in
                defer { continuation = nil }
                return continuation
            }
            continuation?.resume(with: result)
        }
        return try await withCheckedThrowingContinuation { continuation in
            pending.withLock { $0 = continuation }
            let work = Task {
                do {
                    try await resume(.success(operation()))
                } catch {
                    resume(.failure(error))
                }
            }
            Task {
                try? await Task.sleep(for: timeout)
                resume(.failure(Expired()))
                work.cancel()
            }
        }
    }
}
