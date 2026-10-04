import Foundation

struct SubtitleDependencies: Sendable {
    let store: any SubtitleStoring
    let audio: any SourceAudioAccessing
    /// `nil` before macOS 26: text is then shown untimed.
    let recognizer: (any SpeechRecognizing)?
    let fileChooser: any SubtitleFileChoosing
}

enum SubtitleWorkPhase: Equatable, Sendable {
    case downloadingModel
    case aligning
}

struct SubtitleWork: Equatable, Sendable {
    var phase: SubtitleWorkPhase
    var fraction: Double
}

enum SubtitleNotice: Equatable, Sendable {
    case alignmentFailed
}

struct SubtitleTranscript: Equatable, Sendable {
    let cues: [SubtitleCue]
    let paragraphs: [Range<Int>]

    init(cues: [SubtitleCue]) {
        self.cues = cues
        paragraphs = SubtitleTimeline.paragraphs(cues)
    }
}

enum SubtitleDisplay: Equatable, Sendable {
    case loading
    case empty
    case plainText(String, notice: SubtitleNotice?)
    case working(SubtitleWork, text: String)
    case timed(SubtitleTranscript)
}

struct SubtitleSourceOption: Equatable, Identifiable, Sendable {
    let kind: SubtitleSourceKind
    let name: String

    var id: SubtitleSourceKind {
        kind
    }
}

/// Owns the Subtitles inspector: picks the source, loads or builds timed cues, and runs
/// on-device recognition for text alignment. Playback and recording never wait on it.
@MainActor
final class SubtitlesViewModel: ObservableObject {
    @Published var display = SubtitleDisplay.loading
    @Published var sources: [SubtitleSourceOption] = []
    @Published var activeSource: SubtitleSourceKind?
    /// Why recognition failed; shown as help on the failure notice.
    @Published var failureDetail: String?

    var onError: ((any Error) -> Void)?
    /// A .txt picked from "Add Subtitles or Text…" goes through the script attachment flow.
    var onTextChosen: ((URL) -> Void)?

    let projectID: UUID
    let bookmark: Data
    let duration: TimeInterval
    let dependencies: SubtitleDependencies?
    private(set) var script: SubtitleScript?
    var manifest = SubtitleManifest()
    private(set) var loadTask: Task<Void, Never>?

    init(project: AudioProject, dependencies: SubtitleDependencies?) {
        projectID = project.id
        bookmark = project.sourceBookmark
        duration = project.duration
        self.dependencies = dependencies
    }

    deinit {
        loadTask?.cancel()
    }

    var canAddFiles: Bool {
        dependencies != nil
    }

    var activeSourceName: String? {
        sources.first { $0.kind == activeSource }?.name
    }

    func load(script: SubtitleScript?) {
        self.script = script
        restart { model in
            await model.reload()
        }
    }

    /// A newly attached text becomes the current source.
    func scriptDidChange(_ script: SubtitleScript?) {
        self.script = script
        restart { model in
            if script != nil {
                await model.updateManifest { $0.selectedSource = .alignedText }
            }
            await model.reload()
        }
    }

    func select(_ kind: SubtitleSourceKind) {
        guard kind != activeSource else {
            return
        }
        restart { model in
            await model.updateManifest { $0.selectedSource = kind }
            await model.reload()
        }
    }

    func addSubtitleFile() {
        choose(includingText: false)
    }

    func addSubtitlesOrText() {
        choose(includingText: true)
    }

    func importSubtitleFile(from url: URL) {
        guard let store = dependencies?.store else {
            return
        }
        restart { model in
            do {
                let attached = try await store.importSubtitleFile(from: url, projectID: model.projectID)
                await model.updateManifest { manifest in
                    manifest.attachedFile = attached
                    manifest.selectedSource = .subtitleFile
                }
            } catch {
                model.onError?(error)
            }
            await model.reload()
        }
    }

    func close() {
        loadTask?.cancel()
        loadTask = nil
    }

    private func choose(includingText: Bool) {
        guard let chooser = dependencies?.fileChooser else {
            return
        }
        Task { [weak self] in
            guard let url = await chooser.chooseSubtitleFile(includingText: includingText) else {
                return
            }
            if url.pathExtension.lowercased() == "txt" {
                self?.onTextChosen?(url)
            } else {
                self?.importSubtitleFile(from: url)
            }
        }
    }

    /// One piece of work at a time; a new request cancels the previous one.
    private func restart(_ work: @escaping @MainActor (SubtitlesViewModel) async -> Void) {
        loadTask?.cancel()
        loadTask = Task { [weak self] in
            guard let self else {
                return
            }
            await work(self)
        }
    }

    func show(_ newDisplay: SubtitleDisplay) {
        guard !Task.isCancelled, display != newDisplay else {
            return
        }
        display = newDisplay
    }

    func updateManifest(_ change: (inout SubtitleManifest) -> Void) async {
        guard let store = dependencies?.store else {
            return
        }
        do {
            var updated = try await store.manifest(projectID: projectID)
            change(&updated)
            try await store.saveManifest(updated, projectID: projectID)
            manifest = updated
        } catch {
            onError?(error)
        }
    }
}
