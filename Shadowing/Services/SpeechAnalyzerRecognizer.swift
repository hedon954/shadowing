@preconcurrency import AVFoundation
import CoreMedia
import Foundation
import Speech

/// Recognizes English speech on this Mac with `SpeechAnalyzer` (macOS 26). Generated and
/// aligned subtitles are always English, so the locale is fixed rather than following the
/// app or system language. The audio is read locally and never uploaded.
@available(macOS 26, *)
struct SpeechAnalyzerRecognizer: SpeechRecognizing {
    static let locale = Locale(identifier: "en-US")

    /// Used both for the model download and for recognition, so both use `locale`.
    static func makeTranscriber() -> SpeechTranscriber {
        SpeechTranscriber(
            locale: locale,
            transcriptionOptions: [],
            reportingOptions: [],
            attributeOptions: [.audioTimeRange]
        )
    }

    func recognize(
        audioURL: URL,
        duration: TimeInterval
    ) -> AsyncThrowingStream<SpeechRecognitionEvent, any Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await Self.run(audioURL: audioURL, duration: duration, continuation: continuation)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }

    private static func run(
        audioURL: URL,
        duration: TimeInterval,
        continuation: AsyncThrowingStream<SpeechRecognitionEvent, any Error>.Continuation
    ) async throws {
        guard SpeechTranscriber.isAvailable,
              await SpeechTranscriber.supportedLocale(equivalentTo: locale) != nil
        else {
            throw SpeechRecognitionError.unavailable
        }
        let transcriber = makeTranscriber()
        try await installModelIfNeeded(for: transcriber, continuation: continuation)
        try Task.checkCancellation()

        let audioFile: AVAudioFile
        do {
            audioFile = try AVAudioFile(forReading: audioURL)
        } catch {
            throw SpeechRecognitionError.unreadableAudio(error.localizedDescription)
        }
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let collector = Task {
            for try await result in transcriber.results {
                let end = result.range.end.seconds
                let progress = duration > 0 && end.isFinite ? min(max(end / duration, 0), 1) : 0
                continuation.yield(.recognized(words: words(in: result), progress: progress))
            }
        }
        do {
            try await withTaskCancellationHandler {
                if let lastSample = try await analyzer.analyzeSequence(from: audioFile) {
                    try await analyzer.finalizeAndFinish(through: lastSample)
                } else {
                    await analyzer.cancelAndFinishNow()
                }
            } onCancel: {
                Task {
                    await analyzer.cancelAndFinishNow()
                }
            }
            try await collector.value
        } catch {
            collector.cancel()
            throw error
        }
    }

    private static func installModelIfNeeded(
        for transcriber: SpeechTranscriber,
        continuation: AsyncThrowingStream<SpeechRecognitionEvent, any Error>.Continuation
    ) async throws {
        guard let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) else {
            return
        }
        continuation.yield(.downloadingModel(fraction: 0))
        let observation = request.progress.observe(\.fractionCompleted, options: [.new]) { progress, _ in
            continuation.yield(.downloadingModel(fraction: progress.fractionCompleted))
        }
        defer {
            observation.invalidate()
        }
        try await request.downloadAndInstall()
    }

    static func words(in result: SpeechTranscriber.Result) -> [TranscribedWord] {
        let runs = result.text.runs.map { run in
            RecognizedRun(
                text: String(result.text[run.range].characters),
                time: run.audioTimeRange.map { $0.start.seconds ... max($0.start.seconds, $0.end.seconds) }
            )
        }
        return RecognizedRun.words(from: runs)
    }
}
