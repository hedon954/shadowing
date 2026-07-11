import Foundation

enum RecordingFileStoreError: Error, Equatable, LocalizedError, Sendable {
    case invalidRelativePath(String)
    case unmanagedTemporaryFile(String)
    case temporaryFileMissing(String)
    case temporaryFileEmpty(String)
    case destinationAlreadyExists(String)
    case fileOperationFailed(path: String, reason: String)

    var errorDescription: String? {
        switch self {
        case let .invalidRelativePath(path):
            "The recording path is invalid: \(path)."
        case let .unmanagedTemporaryFile(path):
            "The temporary recording is outside the managed directory: \(path)."
        case let .temporaryFileMissing(path):
            "The temporary recording does not exist: \(path)."
        case let .temporaryFileEmpty(path):
            "The temporary recording is empty: \(path)."
        case let .destinationAlreadyExists(path):
            "A committed recording already exists: \(path)."
        case let .fileOperationFailed(path, reason):
            "The recording file operation failed at \(path): \(reason)"
        }
    }
}

struct LocalRecordingFileStore: RecordingFileStore {
    private let rootDirectory: URL

    init(rootDirectory: URL) {
        self.rootDirectory = rootDirectory.standardizedFileURL
    }

    func temporaryTakeURL(id: UUID) throws -> URL {
        let directory = temporaryDirectory
        try createDirectory(directory)
        return directory.appendingPathComponent("\(id.uuidString).caf", isDirectory: false)
    }

    func discardTemporaryTake(at temporaryURL: URL) throws {
        let temporaryURL = temporaryURL.standardizedFileURL
        guard isDescendant(temporaryURL, of: temporaryDirectory) else {
            throw RecordingFileStoreError.unmanagedTemporaryFile(temporaryURL.path)
        }
        guard FileManager.default.fileExists(atPath: temporaryURL.path) else {
            return
        }
        do {
            try FileManager.default.removeItem(at: temporaryURL)
        } catch {
            throw RecordingFileStoreError.fileOperationFailed(
                path: temporaryURL.path,
                reason: error.localizedDescription
            )
        }
    }

    func commitTemporaryTake(
        at temporaryURL: URL,
        projectID: UUID,
        takeID: UUID,
        replaceExisting: Bool = false
    ) throws -> String {
        let temporaryURL = temporaryURL.standardizedFileURL
        guard isDescendant(temporaryURL, of: temporaryDirectory) else {
            throw RecordingFileStoreError.unmanagedTemporaryFile(temporaryURL.path)
        }

        let values: URLResourceValues
        do {
            values = try temporaryURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        } catch {
            throw RecordingFileStoreError.temporaryFileMissing(temporaryURL.path)
        }
        guard values.isRegularFile == true else {
            throw RecordingFileStoreError.temporaryFileMissing(temporaryURL.path)
        }
        guard let fileSize = values.fileSize, fileSize > 0 else {
            throw RecordingFileStoreError.temporaryFileEmpty(temporaryURL.path)
        }

        let relativePath = "projects/\(projectID.uuidString)/\(takeID.uuidString).caf"
        let destinationURL = try audioURL(relativePath: relativePath)
        try createDirectory(destinationURL.deletingLastPathComponent())

        if FileManager.default.fileExists(atPath: destinationURL.path) {
            guard replaceExisting else {
                throw RecordingFileStoreError.destinationAlreadyExists(destinationURL.path)
            }
            do {
                try FileManager.default.removeItem(at: destinationURL)
            } catch {
                throw RecordingFileStoreError.fileOperationFailed(
                    path: destinationURL.path,
                    reason: error.localizedDescription
                )
            }
        }

        do {
            try FileManager.default.moveItem(at: temporaryURL, to: destinationURL)
        } catch {
            throw RecordingFileStoreError.fileOperationFailed(
                path: destinationURL.path,
                reason: error.localizedDescription
            )
        }
        return relativePath
    }

    func audioURL(relativePath: String) throws -> URL {
        guard !relativePath.isEmpty,
              !(relativePath as NSString).isAbsolutePath,
              !relativePath.split(separator: "/").contains("..")
        else {
            throw RecordingFileStoreError.invalidRelativePath(relativePath)
        }

        let url = rootDirectory
            .appendingPathComponent(relativePath, isDirectory: false)
            .standardizedFileURL
        guard isDescendant(url, of: rootDirectory) else {
            throw RecordingFileStoreError.invalidRelativePath(relativePath)
        }
        return url
    }

    func deleteAudio(relativePath: String) throws {
        let url = try audioURL(relativePath: relativePath)
        guard FileManager.default.fileExists(atPath: url.path) else {
            return
        }
        do {
            try FileManager.default.removeItem(at: url)
        } catch {
            throw RecordingFileStoreError.fileOperationFailed(
                path: url.path,
                reason: error.localizedDescription
            )
        }
    }

    func removeOrphanedTemporaryTakes() throws -> Int {
        let directory = temporaryDirectory
        guard FileManager.default.fileExists(atPath: directory.path) else {
            return 0
        }

        let contents: [URL]
        do {
            contents = try FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            )
        } catch {
            throw RecordingFileStoreError.fileOperationFailed(
                path: directory.path,
                reason: error.localizedDescription
            )
        }

        var removed = 0
        for url in contents {
            let values: URLResourceValues
            do {
                values = try url.resourceValues(forKeys: [.isRegularFileKey])
            } catch {
                throw RecordingFileStoreError.fileOperationFailed(
                    path: url.path,
                    reason: error.localizedDescription
                )
            }
            guard values.isRegularFile == true else {
                continue
            }
            do {
                try FileManager.default.removeItem(at: url)
                removed += 1
            } catch {
                throw RecordingFileStoreError.fileOperationFailed(
                    path: url.path,
                    reason: error.localizedDescription
                )
            }
        }
        return removed
    }

    private var temporaryDirectory: URL {
        rootDirectory.appendingPathComponent(".temporary", isDirectory: true)
    }

    private func createDirectory(_ url: URL) throws {
        do {
            try FileManager.default.createDirectory(
                at: url,
                withIntermediateDirectories: true
            )
        } catch {
            throw RecordingFileStoreError.fileOperationFailed(
                path: url.path,
                reason: error.localizedDescription
            )
        }
    }

    private func isDescendant(_ url: URL, of directory: URL) -> Bool {
        let directoryPath = directory.standardizedFileURL.path
        let urlPath = url.standardizedFileURL.path
        return urlPath.hasPrefix(directoryPath + "/")
    }
}

enum TakeCommitError: Error, Equatable, LocalizedError, Sendable {
    case metadataSaveFailed(relativePath: String, reason: String)
    case rollbackFailed(relativePath: String, saveReason: String, rollbackReason: String)

    var errorDescription: String? {
        switch self {
        case let .metadataSaveFailed(relativePath, reason):
            "Could not save metadata for \(relativePath): \(reason)"
        case let .rollbackFailed(relativePath, saveReason, rollbackReason):
            """
            Could not save metadata for \(relativePath) (\(saveReason)) or remove the committed \
            recording (\(rollbackReason)).
            """
        }
    }
}

struct RecordingTakeCommitter: TakeCommitting {
    private let fileStore: any RecordingFileStore
    private let takeRepository: any TakeRepository
    private let validator: any RecordingFileValidating

    init(
        fileStore: any RecordingFileStore,
        takeRepository: any TakeRepository,
        validator: any RecordingFileValidating
    ) {
        self.fileStore = fileStore
        self.takeRepository = takeRepository
        self.validator = validator
    }

    func commit(
        _ draft: TakeDraft,
        temporaryFile: URL,
        replaceExisting: Bool
    ) async throws -> Take {
        try validator.validatePlayableRecording(at: temporaryFile)
        let relativePath = try fileStore.commitTemporaryTake(
            at: temporaryFile,
            projectID: draft.projectID,
            takeID: draft.id,
            replaceExisting: replaceExisting
        )
        let take = try draft.makeTake(relativeAudioPath: relativePath)

        do {
            try await takeRepository.save(take)
            return take
        } catch {
            let saveReason = error.localizedDescription
            do {
                try fileStore.deleteAudio(relativePath: relativePath)
            } catch {
                throw TakeCommitError.rollbackFailed(
                    relativePath: relativePath,
                    saveReason: saveReason,
                    rollbackReason: error.localizedDescription
                )
            }
            throw TakeCommitError.metadataSaveFailed(
                relativePath: relativePath,
                reason: saveReason
            )
        }
    }
}
