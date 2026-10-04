import Foundation

/// "Generate Subtitles from Audio": English recognition on this Mac, saved as the project's
/// .srt. Nothing runs until the user asks, and the audio is never uploaded.
extension SubtitlesViewModel {
    func runGeneration() async {
        guard let dependencies, let recognizer = dependencies.recognizer else {
            return
        }
        isGenerating = true
        defer {
            isGenerating = false
        }
        failureDetail = nil
        show(.working(SubtitleWork(phase: .recognizing, fraction: 0), text: ""))
        do {
            let audioHash = try await dependencies.audio.fingerprint(bookmark: bookmark)
            try Task.checkCancellation()
            let words = try await recognizedWords(
                audioHash: audioHash,
                recognizer: recognizer,
                dependencies: dependencies,
                phase: .recognizing,
                text: nil
            )
            let cues = await Self.segment(words)
            try Task.checkCancellation()
            guard !cues.isEmpty else {
                throw SpeechRecognitionError.noSpeech
            }
            manifest = try await dependencies.store.manifest(projectID: projectID)
            manifest.generated = GeneratedSubtitlesRecord(audioSHA256: audioHash)
            manifest.selectedSource = .fromAudio
            try await saveCurrent(cues, provenance: Self.generatedProvenance(audioHash), store: dependencies.store)
            await reload()
        } catch {
            guard !Task.isCancelled, !(error is CancellationError) else {
                return
            }
            await reload()
            generationError = error.localizedDescription
        }
    }

    /// Shows generated subtitles: the saved .srt while it is current, otherwise rebuilt from
    /// the cached words without recognizing again.
    func showGenerated(store: any SubtitleStoring) async {
        guard let generated = manifest.generated else {
            show(fallbackDisplay)
            return
        }
        let provenance = Self.generatedProvenance(generated.audioSHA256)
        do {
            if manifest.current == provenance, let cues = try await store.subtitles(projectID: projectID) {
                show(.timed(SubtitleTranscript(cues: cues)))
                return
            }
            guard let speech = try await store.recognizedSpeech(projectID: projectID),
                  speech.audioSHA256 == generated.audioSHA256
            else {
                show(fallbackDisplay)
                return
            }
            let cues = await Self.segment(speech.words)
            try Task.checkCancellation()
            try await saveCurrent(cues, provenance: provenance, store: store)
            show(.timed(SubtitleTranscript(cues: cues)))
        } catch {
            guard !Task.isCancelled else {
                return
            }
            onError?(error)
            show(fallbackDisplay)
        }
    }

    private static func generatedProvenance(_ audioHash: String) -> SubtitleProvenance {
        SubtitleProvenance(source: .fromAudio, inputSHA256: audioHash, audioSHA256: audioHash)
    }

    private nonisolated static func segment(_ words: [TranscribedWord]) async -> [SubtitleCue] {
        SubtitleSegmenter.cues(from: words)
    }

    /// Writes an exported .srt to the place the user picked in the save panel.
    nonisolated static func write(_ srt: String, to url: URL) async throws {
        do {
            try Data(srt.utf8).write(to: url, options: .atomic)
        } catch {
            throw SubtitleStoreError.fileOperationFailed(path: url.path, reason: error.localizedDescription)
        }
    }
}
