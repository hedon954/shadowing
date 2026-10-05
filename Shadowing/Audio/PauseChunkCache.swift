import CryptoKit
import Foundation

protocol PauseChunkProviding: Sendable {
    func chunks(projectID: UUID, waveform: WaveformPresentation) async -> [SentenceChunk]
}

/// Computes pause chunks off the main actor, without a cache. Tests and previews use this.
struct ComputedPauseChunks: PauseChunkProviding {
    func chunks(projectID _: UUID, waveform: WaveformPresentation) async -> [SentenceChunk] {
        await Task.detached(priority: .utility) {
            PauseSegmenter.chunks(in: waveform)
        }.value
    }
}

/// Pause chunks cached as JSON next to the waveform cache, keyed by project and waveform shape.
actor CachedPauseChunks: PauseChunkProviding {
    static let cacheVersion = 1

    private let directory: URL

    init(directory: URL) {
        self.directory = directory.standardizedFileURL
    }

    func chunks(projectID: UUID, waveform: WaveformPresentation) async -> [SentenceChunk] {
        let url = cacheURL(projectID: projectID, waveform: waveform)
        let cached = (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode([SentenceChunk].self, from: $0) }
        if let cached {
            return cached
        }
        let computed = await ComputedPauseChunks().chunks(projectID: projectID, waveform: waveform)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try JSONEncoder().encode(computed).write(to: url, options: .atomic)
        } catch {
            // A missing cache only costs a recomputation next time.
            _ = error
        }
        return computed
    }

    func cacheURL(projectID: UUID, waveform: WaveformPresentation) -> URL {
        directory.appendingPathComponent(
            "pauses-v\(Self.cacheVersion)-\(projectID.uuidString)-\(Self.signature(of: waveform)).json",
            isDirectory: false
        )
    }

    /// Changes when the audio behind the waveform changes (length, rate or envelope).
    static func signature(of waveform: WaveformPresentation) -> String {
        var hasher = SHA256()
        var header = "\(waveform.duration)-\(waveform.sampleRate)"
        if let level = waveform.levels.first {
            header += "-\(level.framesPerPoint)-\(level.points.count)"
            let sample = stride(from: 0, to: level.points.count, by: max(level.points.count / 256, 1))
                .map { String(format: "%.4f", level.points[$0].amplitude) }
                .joined(separator: ",")
            hasher.update(data: Data(sample.utf8))
        }
        hasher.update(data: Data(header.utf8))
        return hasher.finalize().prefix(8).map { String(format: "%02x", $0) }.joined()
    }
}
