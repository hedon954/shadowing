@preconcurrency import AppKit
@preconcurrency import AVFoundation
import Foundation
import UniformTypeIdentifiers

struct SystemAudioFileChooser: AudioFileChoosing {
    @MainActor
    func chooseMP3() async -> URL? {
        let panel = NSOpenPanel()
        panel.title = "Choose an MP3"
        panel.prompt = "Choose File"
        panel.allowedContentTypes = [.mp3]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        return panel.runModal() == .OK ? panel.url : nil
    }
}

struct MP3FileValidator: AudioFileValidating {
    func validate(_ url: URL) throws {
        guard url.isFileURL,
              url.pathExtension.lowercased() == "mp3"
        else {
            throw AudioSourceError.unsupportedFormat
        }
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: url.path) else {
            throw AudioSourceError.fileMissing
        }
        guard fileManager.isReadableFile(atPath: url.path) else {
            throw AudioSourceError.permissionDenied
        }
    }
}

struct AVAssetMetadataLoader: AudioAssetMetadataLoading {
    func loadMetadata(from url: URL) async throws -> AudioAssetMetadata {
        try Task.checkCancellation()
        let asset = AVURLAsset(url: url)

        do {
            async let isPlayable = asset.load(.isPlayable)
            async let duration = asset.load(.duration)
            async let audioTracks = asset.loadTracks(withMediaType: .audio)
            let values = try await (isPlayable, duration, audioTracks)
            try Task.checkCancellation()

            guard values.0 else {
                throw AudioSourceError.corruptFile
            }
            guard !values.2.isEmpty else {
                throw AudioSourceError.noAudioTrack
            }

            let seconds = values.1.seconds
            guard seconds.isFinite, seconds > 0 else {
                throw AudioSourceError.invalidDuration
            }
            return AudioAssetMetadata(
                displayName: url.lastPathComponent,
                duration: seconds
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as AudioSourceError {
            throw error
        } catch {
            throw AudioSourceError.corruptFile
        }
    }
}
