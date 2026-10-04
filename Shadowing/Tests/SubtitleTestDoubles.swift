import Foundation
@testable import Shadowing

actor CallCounter {
    private(set) var count = 0

    func increment() {
        count += 1
    }
}

/// Replays fixed recognition events; never touches audio or the network.
struct FakeSpeechRecognizer: SpeechRecognizing {
    var events: [SpeechRecognitionEvent]
    var failure: SpeechRecognitionError?
    let calls = CallCounter()

    init(words: [TranscribedWord] = [], failure: SpeechRecognitionError? = nil) {
        events = [.downloadingModel(fraction: 1), .recognized(words: words, progress: 1)]
        self.failure = failure
    }

    func recognize(
        audioURL _: URL,
        duration _: TimeInterval
    ) -> AsyncThrowingStream<SpeechRecognitionEvent, any Error> {
        let events = events
        let failure = failure
        let calls = calls
        return AsyncThrowingStream { continuation in
            let task = Task {
                await calls.increment()
                for event in events {
                    continuation.yield(event)
                }
                if let failure {
                    continuation.finish(throwing: failure)
                } else {
                    continuation.finish()
                }
            }
            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }
}

struct FakeSourceAudio: SourceAudioAccessing {
    var hash = "audio-1"

    func fingerprint(bookmark _: Data) async throws -> String {
        hash
    }

    func withAudioFile<Value: Sendable>(
        bookmark _: Data,
        _ operation: @Sendable (URL) async throws -> Value
    ) async throws -> Value {
        try await operation(URL(fileURLWithPath: "/dev/null"))
    }
}

struct StubSubtitleChooser: SubtitleFileChoosing {
    var url: URL?
    var exportURL: URL?

    @MainActor
    func chooseSubtitleFile(includingText _: Bool) async -> URL? {
        url
    }

    @MainActor
    func chooseExportDestination(suggestedName _: String) async -> URL? {
        exportURL
    }
}

enum SubtitleTestSupport {
    /// Words spoken one after another, `step` seconds each, starting at `start`.
    static func words(_ text: String, start: TimeInterval = 0, step: TimeInterval = 0.5) -> [TranscribedWord] {
        text.split(separator: " ").enumerated().map { index, word in
            let wordStart = start + Double(index) * step
            return TranscribedWord(text: String(word), start: wordStart, end: wordStart + step * 0.8)
        }
    }

    static func makeDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ShadowingSubtitles-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
