import CryptoKit
import Foundation

struct SourceFingerprint: Codable, Equatable, Hashable, Sendable {
    let pathDigest: String
    let fileSize: Int64
    let modificationTimeNanoseconds: Int64

    static func make(for sourceURL: URL) throws -> SourceFingerprint {
        let attributes = try FileManager.default.attributesOfItem(atPath: sourceURL.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              let fileSize = attributes[.size] as? NSNumber,
              let modificationDate = attributes[.modificationDate] as? Date
        else {
            throw WaveformCacheError.invalidSource(sourceURL.path)
        }

        let pathData = Data(sourceURL.standardizedFileURL.path.utf8)
        let digest = SHA256.hash(data: pathData).map { String(format: "%02x", $0) }.joined()
        let modificationTime = modificationDate.timeIntervalSince1970 * 1_000_000_000
        return SourceFingerprint(
            pathDigest: digest,
            fileSize: fileSize.int64Value,
            modificationTimeNanoseconds: Int64(
                modificationTime.rounded(.toNearestOrAwayFromZero)
            )
        )
    }

    var cacheKey: String {
        "\(pathDigest)-\(fileSize)-\(modificationTimeNanoseconds)"
    }
}

struct WaveformPeakLevel: Codable, Equatable, Sendable {
    let framesPerPeak: Int
    let peaks: [Float]
}

struct WaveformData: Codable, Equatable, Sendable {
    let fingerprint: SourceFingerprint
    let duration: TimeInterval
    let sampleRate: Double
    let levels: [WaveformPeakLevel]
}

enum WaveformCacheError: Error, Equatable, LocalizedError, Sendable {
    case invalidSource(String)
    case cacheReadFailed(path: String, reason: String)
    case cacheWriteFailed(path: String, reason: String)

    var errorDescription: String? {
        switch self {
        case let .invalidSource(path):
            "Cannot fingerprint the waveform source at \(path)."
        case let .cacheReadFailed(path, reason):
            "Cannot read waveform cache at \(path): \(reason)"
        case let .cacheWriteFailed(path, reason):
            "Cannot write waveform cache at \(path): \(reason)"
        }
    }
}

actor WaveformFileCache {
    private let directory: URL
    private let fileManager: FileManager

    init(directory: URL, fileManager: FileManager = .default) {
        self.directory = directory.standardizedFileURL
        self.fileManager = fileManager
    }

    func load(for fingerprint: SourceFingerprint) throws -> WaveformData? {
        let url = cacheURL(for: fingerprint)
        guard fileManager.fileExists(atPath: url.path) else {
            return nil
        }
        do {
            let data = try Data(contentsOf: url)
            let waveform = try PropertyListDecoder().decode(WaveformData.self, from: data)
            guard waveform.fingerprint == fingerprint else {
                return nil
            }
            return waveform
        } catch {
            throw WaveformCacheError.cacheReadFailed(
                path: url.path,
                reason: error.localizedDescription
            )
        }
    }

    func store(_ waveform: WaveformData) throws {
        do {
            try fileManager.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
            let encoder = PropertyListEncoder()
            encoder.outputFormat = .binary
            let data = try encoder.encode(waveform)
            try data.write(to: cacheURL(for: waveform.fingerprint), options: .atomic)
        } catch {
            throw WaveformCacheError.cacheWriteFailed(
                path: cacheURL(for: waveform.fingerprint).path,
                reason: error.localizedDescription
            )
        }
    }

    func remove(for fingerprint: SourceFingerprint) throws {
        let url = cacheURL(for: fingerprint)
        guard fileManager.fileExists(atPath: url.path) else {
            return
        }
        do {
            try fileManager.removeItem(at: url)
        } catch {
            throw WaveformCacheError.cacheWriteFailed(
                path: url.path,
                reason: error.localizedDescription
            )
        }
    }

    private func cacheURL(for fingerprint: SourceFingerprint) -> URL {
        directory.appendingPathComponent("\(fingerprint.cacheKey).waveform", isDirectory: false)
    }
}
