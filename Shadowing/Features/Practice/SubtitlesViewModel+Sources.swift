import Foundation

/// Source selection and the work behind each source: parsing an attached file, or aligning
/// the text with words recognized on this Mac.
extension SubtitlesViewModel {
    func reload() async {
        guard let dependencies else {
            sources = script.map { [SubtitleSourceOption(kind: .alignedText, name: $0.displayName)] } ?? []
            activeSource = sources.first?.kind
            show(script.map { .plainText($0.text, notice: nil) } ?? .empty)
            return
        }
        do {
            manifest = try await dependencies.store.manifest(projectID: projectID)
        } catch {
            guard !Task.isCancelled else {
                return
            }
            onError?(error)
            manifest = SubtitleManifest()
        }
        guard !Task.isCancelled else {
            return
        }
        let available = SubtitleSourcePlanner.availableSources(manifest: manifest, hasScript: script != nil)
        sources = available.map { SubtitleSourceOption(kind: $0, name: sourceName($0)) }
        if canGenerate, !available.contains(.fromAudio) {
            // Listed so it can be picked; choosing it starts generation.
            sources.append(SubtitleSourceOption(kind: .fromAudio, name: sourceName(.fromAudio), isReady: false))
        }
        activeSource = SubtitleSourcePlanner.activeSource(manifest: manifest, available: available)
        failureDetail = nil
        switch activeSource {
        case nil:
            show(.empty)
        case .subtitleFile:
            await showSubtitleFile(store: dependencies.store)
        case .alignedText:
            await showAlignedText(dependencies)
        case .fromAudio:
            await showGenerated(store: dependencies.store)
        }
    }

    private func sourceName(_ kind: SubtitleSourceKind) -> String {
        switch kind {
        case .subtitleFile:
            manifest.attachedFile?.displayName ?? ""
        case .alignedText:
            script?.displayName ?? ""
        case .fromAudio:
            String(localized: "From audio")
        }
    }

    var fallbackDisplay: SubtitleDisplay {
        script.map { .plainText($0.text, notice: nil) } ?? .empty
    }

    private func showSubtitleFile(store: any SubtitleStoring) async {
        guard let attached = manifest.attachedFile else {
            show(fallbackDisplay)
            return
        }
        let provenance = SubtitleProvenance(source: .subtitleFile, inputSHA256: attached.sha256, audioSHA256: nil)
        do {
            if manifest.current == provenance, let cues = try await store.subtitles(projectID: projectID) {
                show(.timed(SubtitleTranscript(cues: cues)))
                return
            }
            guard let text = try await store.attachedSubtitleText(projectID: projectID, format: attached.format) else {
                throw SubtitleStoreError.unreadableText(attached.displayName)
            }
            let cues = try await Self.parse(text, format: attached.format)
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

    private func showAlignedText(_ dependencies: SubtitleDependencies) async {
        guard let script else {
            show(.empty)
            return
        }
        guard let recognizer = dependencies.recognizer else {
            show(.plainText(script.text, notice: nil))
            return
        }
        let textHash = ContentHash.sha256(script.text)
        do {
            let audioHash = try await dependencies.audio.fingerprint(bookmark: bookmark)
            try Task.checkCancellation()
            let provenance = SubtitleProvenance(source: .alignedText, inputSHA256: textHash, audioSHA256: audioHash)
            if manifest.current == provenance, let cues = try await dependencies.store.subtitles(projectID: projectID) {
                show(.timed(SubtitleTranscript(cues: cues)))
                return
            }
            let failedBefore = manifest.lastAlignment.map { record in
                record.textSHA256 == textHash && record.audioSHA256 == audioHash && !record.succeeded
            } ?? false
            if failedBefore {
                show(.plainText(script.text, notice: .alignmentFailed))
                return
            }
            let words = try await recognizedWords(
                audioHash: audioHash,
                recognizer: recognizer,
                dependencies: dependencies,
                phase: .aligning,
                text: script.text
            )
            let alignment = await Self.align(script.text, words)
            try Task.checkCancellation()
            manifest.lastAlignment = TextAlignmentRecord(
                textSHA256: textHash,
                audioSHA256: audioHash,
                matchRatio: alignment.matchRatio
            )
            if alignment.isAligned {
                try await saveCurrent(alignment.cues, provenance: provenance, store: dependencies.store)
                show(.timed(SubtitleTranscript(cues: alignment.cues)))
            } else {
                try await dependencies.store.saveManifest(manifest, projectID: projectID)
                show(.plainText(script.text, notice: .alignmentFailed))
            }
        } catch {
            guard !Task.isCancelled, !(error is CancellationError) else {
                return
            }
            failureDetail = error.localizedDescription
            show(.plainText(script.text, notice: .alignmentFailed))
        }
    }

    /// Cached words for this exact audio, otherwise a recognition pass on this Mac.
    /// With no `text`, the words recognized so far are shown as they arrive.
    func recognizedWords(
        audioHash: String,
        recognizer: any SpeechRecognizing,
        dependencies: SubtitleDependencies,
        phase: SubtitleWorkPhase,
        text: String?
    ) async throws -> [TranscribedWord] {
        let cached = try await dependencies.store.recognizedSpeech(projectID: projectID)
        if let cached, cached.audioSHA256 == audioHash {
            return cached.words
        }
        show(.working(SubtitleWork(phase: phase, fraction: 0), text: text ?? ""))
        let duration = duration
        let words = try await dependencies.audio.withAudioFile(bookmark: bookmark) { [weak self] url in
            var words: [TranscribedWord] = []
            for try await event in recognizer.recognize(audioURL: url, duration: duration) {
                if case let .recognized(newWords, _) = event {
                    words += newWords
                }
                let shown = text ?? SubtitleSegmenter.text(of: words)
                await self?.receive(event, phase: phase, text: shown)
            }
            return words
        }
        try Task.checkCancellation()
        try await dependencies.store.saveRecognizedSpeech(
            RecognizedSpeech(audioSHA256: audioHash, words: words),
            projectID: projectID
        )
        return words
    }

    func receive(_ event: SpeechRecognitionEvent, phase: SubtitleWorkPhase, text: String) {
        let work = switch event {
        case let .downloadingModel(fraction):
            SubtitleWork(phase: .downloadingModel, fraction: fraction)
        case let .recognized(_, progress):
            SubtitleWork(phase: phase, fraction: progress)
        }
        // Download progress reports often; whole percents are enough for the bar.
        if case let .working(current, shown) = display, current.phase == work.phase, shown == text {
            guard abs(current.fraction - work.fraction) >= 0.01 else {
                return
            }
        }
        show(.working(work, text: text))
    }

    func saveCurrent(
        _ cues: [SubtitleCue],
        provenance: SubtitleProvenance,
        store: any SubtitleStoring
    ) async throws {
        try await store.saveSubtitles(cues, projectID: projectID)
        manifest.current = provenance
        try await store.saveManifest(manifest, projectID: projectID)
    }

    private nonisolated static func parse(_ text: String, format: SubtitleFileFormat) async throws -> [SubtitleCue] {
        try SubtitleParser.parse(text, format: format)
    }

    private nonisolated static func align(_ script: String, _ words: [TranscribedWord]) async -> TextAlignment {
        TextAligner.align(script: script, words: words)
    }
}
