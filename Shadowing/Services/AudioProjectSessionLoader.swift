import Foundation

actor AudioProjectSessionLoader: PracticeSessionPreparing {
    private let projects: any ProjectRepository
    private let bookmarks: any BookmarkStore
    private let validator: any AudioFileValidating
    private let metadataLoader: any AudioAssetMetadataLoading
    private let waveformService: any WaveformPreparing
    private let audioClient: any PracticeAudioClient
    private let now: @Sendable () -> Date

    private var activeAccess: (any BookmarkAccess)?
    private var generation: UInt64 = 0

    init(
        projects: any ProjectRepository,
        bookmarks: any BookmarkStore,
        validator: any AudioFileValidating,
        metadataLoader: any AudioAssetMetadataLoading,
        waveformService: any WaveformPreparing,
        audioClient: any PracticeAudioClient,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.projects = projects
        self.bookmarks = bookmarks
        self.validator = validator
        self.metadataLoader = metadataLoader
        self.waveformService = waveformService
        self.audioClient = audioClient
        self.now = now
    }

    func prepareNewSource(at url: URL) async throws -> PreparedPractice {
        let currentGeneration = await beginPreparation()
        do {
            try validator.validate(url)
            let bookmark = try bookmarks.createBookmark(for: url)
            return try await prepare(
                bookmark: bookmark,
                existingProject: nil,
                generation: currentGeneration
            )
        } catch {
            throw mapError(error)
        }
    }

    func prepareExistingProject(id: UUID) async throws -> PreparedPractice {
        let existingProject: AudioProject
        do {
            guard let project = try await projects.project(id: id) else {
                throw AudioSourceError.fileMissing
            }
            existingProject = project
        } catch {
            throw mapError(error)
        }

        let currentGeneration = await beginPreparation()
        return try await prepare(
            bookmark: existingProject.sourceBookmark,
            existingProject: existingProject,
            generation: currentGeneration
        )
    }

    func relocateProject(id: UUID, to url: URL) async throws -> PreparedPractice {
        let existingProject: AudioProject
        do {
            guard let project = try await projects.project(id: id) else {
                throw AudioSourceError.fileMissing
            }
            existingProject = project
        } catch {
            throw mapError(error)
        }

        let currentGeneration = await beginPreparation()
        do {
            try validator.validate(url)
            let bookmark = try bookmarks.createBookmark(for: url)
            return try await prepare(
                bookmark: bookmark,
                existingProject: existingProject,
                generation: currentGeneration
            )
        } catch {
            throw mapError(error)
        }
    }

    func endSession() async {
        generation &+= 1
        let access = activeAccess
        activeAccess = nil
        await access?.stop()
    }

    private func beginPreparation() async -> UInt64 {
        generation &+= 1
        let access = activeAccess
        activeAccess = nil
        await access?.stop()
        return generation
    }

    private func prepare(
        bookmark: Data,
        existingProject: AudioProject?,
        generation currentGeneration: UInt64
    ) async throws -> PreparedPractice {
        let access: any BookmarkAccess
        do {
            access = try await bookmarks.beginAccess(to: bookmark)
        } catch {
            throw mapError(error)
        }

        do {
            let resolved = await access.resolvedBookmark
            try ensureCurrent(currentGeneration)
            try validator.validate(resolved.url)

            async let metadataValue = metadataLoader.loadMetadata(from: resolved.url)
            async let waveformValue = prepareWaveformRecovering(from: resolved.url)
            let metadata = try await metadataValue
            try ensureCurrent(currentGeneration)
            try await audioClient.execute(.loadSource(resolved.url))
            let waveform = try await waveformValue
            try ensureCurrent(currentGeneration)

            var project = try makeProject(
                existing: existingProject,
                metadata: metadata,
                bookmark: resolved.isStale
                    ? bookmarks.createBookmark(for: resolved.url)
                    : bookmark
            )
            project.lastOpenedAt = now()
            try await projects.save(project)
            try ensureCurrent(currentGeneration)

            activeAccess = access
            return PreparedPractice(project: project, waveform: waveform)
        } catch {
            await access.stop()
            throw mapError(error)
        }
    }

    private func prepareWaveformRecovering(from url: URL) async throws -> WaveformPresentation {
        do {
            return try await waveformService.prepareWaveform(from: url)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return WaveformPresentation(
                peaks: [],
                warning: "The waveform is unavailable. Audio playback is still available."
            )
        }
    }

    private func makeProject(
        existing: AudioProject?,
        metadata: AudioAssetMetadata,
        bookmark: Data
    ) -> AudioProject {
        var region = existing?.currentRegion
        if let currentRegion = region, currentRegion.end > metadata.duration {
            region = nil
        }
        return AudioProject(
            id: existing?.id ?? UUID(),
            sourceDisplayName: metadata.displayName,
            sourceBookmark: bookmark,
            duration: metadata.duration,
            playhead: min(existing?.playhead ?? 0, metadata.duration),
            currentRegion: region,
            selectedTakeID: existing?.selectedTakeID,
            keptTakeID: existing?.keptTakeID,
            lastOpenedAt: now(),
            playbackRate: Self.normalizedPlaybackRate(existing?.playbackRate)
        )
    }

    private static func normalizedPlaybackRate(_ rate: Double?) -> Double {
        let candidate = rate ?? 1
        let supported: [Double] = [0.5, 0.75, 1, 1.25, 1.5]
        return supported.contains(candidate) ? candidate : 1
    }

    private func ensureCurrent(_ expectedGeneration: UInt64) throws {
        guard !Task.isCancelled, generation == expectedGeneration else {
            throw CancellationError()
        }
    }

    private func mapError(_ error: Error) -> Error {
        if error is CancellationError {
            return CancellationError()
        }
        if let sourceError = error as? AudioSourceError {
            return sourceError
        }
        if let bookmarkError = error as? BookmarkStoreError {
            switch bookmarkError {
            case .accessDenied:
                return AudioSourceError.permissionDenied
            case .resolutionFailed:
                return AudioSourceError.bookmarkStale
            case .creationFailed:
                return AudioSourceError.failed(bookmarkError.localizedDescription)
            }
        }
        return AudioSourceError.failed(error.localizedDescription)
    }
}
