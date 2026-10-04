import Foundation

enum SubtitleStoreError: Error, Equatable, LocalizedError, Sendable {
    case unsupportedFormat(String)
    case unreadableText(String)
    case unreadableManifest(String)
    case fileOperationFailed(path: String, reason: String)

    var errorDescription: String? {
        switch self {
        case let .unsupportedFormat(name):
            String(localized: "\(name) is not a subtitle file. Use .srt, .vtt or .lrc.")
        case let .unreadableText(path):
            String(localized: "The subtitle file could not be read as text: \(path).")
        case let .unreadableManifest(path):
            String(localized: "The subtitle settings file is damaged: \(path).")
        case let .fileOperationFailed(path, reason):
            String(localized: "The subtitle file operation failed at \(path): \(reason)")
        }
    }
}

/// Files in the Subtitles folder, named after the project id:
/// `<id>.srt` (the subtitles shown and exported), `<id>.json` (manifest),
/// `<id>.source.<srt|vtt|lrc>` (copy of an attached file) and `<id>.words.json`
/// (recognized words, rebuildable). Nothing outside this folder is ever written.
actor LocalSubtitleFileStore: SubtitleStoring {
    private let directory: URL

    init(directory: URL) {
        self.directory = directory.standardizedFileURL
    }

    func manifest(projectID: UUID) throws -> SubtitleManifest {
        let url = fileURL(projectID, ".json")
        guard let data = try readIfPresent(url) else {
            return SubtitleManifest()
        }
        do {
            return try JSONDecoder().decode(SubtitleManifest.self, from: data)
        } catch {
            throw SubtitleStoreError.unreadableManifest(url.path)
        }
    }

    func saveManifest(_ manifest: SubtitleManifest, projectID: UUID) throws {
        try write(encoded(manifest), to: fileURL(projectID, ".json"))
    }

    func importSubtitleFile(from url: URL, projectID: UUID) throws -> AttachedSubtitleFile {
        guard let format = SubtitleFileFormat(pathExtension: url.pathExtension) else {
            throw SubtitleStoreError.unsupportedFormat(url.lastPathComponent)
        }
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw SubtitleStoreError.fileOperationFailed(path: url.path, reason: error.localizedDescription)
        }
        guard let text = Self.decodeText(data) else {
            throw SubtitleStoreError.unreadableText(url.path)
        }
        _ = try SubtitleParser.parse(text, format: format)

        for other in SubtitleFileFormat.allCases where other != format {
            try removeIfPresent(sourceURL(projectID, other))
        }
        try write(data, to: sourceURL(projectID, format))
        return AttachedSubtitleFile(
            displayName: url.lastPathComponent,
            format: format,
            sha256: ContentHash.sha256(data)
        )
    }

    func attachedSubtitleText(projectID: UUID, format: SubtitleFileFormat) throws -> String? {
        let url = sourceURL(projectID, format)
        guard let data = try readIfPresent(url) else {
            return nil
        }
        guard let text = Self.decodeText(data) else {
            throw SubtitleStoreError.unreadableText(url.path)
        }
        return text
    }

    func subtitles(projectID: UUID) throws -> [SubtitleCue]? {
        let url = fileURL(projectID, ".srt")
        guard let data = try readIfPresent(url) else {
            return nil
        }
        guard let text = Self.decodeText(data) else {
            throw SubtitleStoreError.unreadableText(url.path)
        }
        return try SubtitleParser.parse(text, format: .srt)
    }

    func saveSubtitles(_ cues: [SubtitleCue], projectID: UUID) throws {
        try write(Data(SubtitleSRTWriter.srt(from: cues).utf8), to: fileURL(projectID, ".srt"))
    }

    func recognizedSpeech(projectID: UUID) throws -> RecognizedSpeech? {
        let url = fileURL(projectID, ".words.json")
        guard let data = try readIfPresent(url) else {
            return nil
        }
        do {
            return try JSONDecoder().decode(RecognizedSpeech.self, from: data)
        } catch {
            // The cache is rebuilt from the audio, so a damaged one just counts as missing.
            try removeIfPresent(url)
            return nil
        }
    }

    func saveRecognizedSpeech(_ speech: RecognizedSpeech, projectID: UUID) throws {
        try write(encoded(speech), to: fileURL(projectID, ".words.json"))
    }

    static func decodeText(_ data: Data) -> String? {
        if data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF]) {
            return String(data: data, encoding: .utf16)
        }
        return String(data: data, encoding: .utf8) ?? String(data: data, encoding: .windowsCP1252)
    }

    private func fileURL(_ projectID: UUID, _ suffix: String) -> URL {
        directory.appendingPathComponent(projectID.uuidString + suffix, isDirectory: false)
    }

    private func sourceURL(_ projectID: UUID, _ format: SubtitleFileFormat) -> URL {
        fileURL(projectID, ".source.\(format.rawValue)")
    }

    private func encoded(_ value: some Encodable) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            return try encoder.encode(value)
        } catch {
            throw SubtitleStoreError.fileOperationFailed(path: directory.path, reason: error.localizedDescription)
        }
    }

    private func readIfPresent(_ url: URL) throws -> Data? {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return nil
        }
        do {
            return try Data(contentsOf: url)
        } catch {
            throw SubtitleStoreError.fileOperationFailed(path: url.path, reason: error.localizedDescription)
        }
    }

    private func write(_ data: Data, to url: URL) throws {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
        } catch {
            throw SubtitleStoreError.fileOperationFailed(path: url.path, reason: error.localizedDescription)
        }
    }

    private func removeIfPresent(_ url: URL) throws {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return
        }
        do {
            try FileManager.default.removeItem(at: url)
        } catch {
            throw SubtitleStoreError.fileOperationFailed(path: url.path, reason: error.localizedDescription)
        }
    }
}
