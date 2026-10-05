import Foundation

/// Moves a file to the Trash and returns where it ended up, so Undo can move it back.
/// Injected so tests use a temporary folder instead of the real Trash.
struct FileTrasher: Sendable {
    let moveToTrash: @Sendable (URL) throws -> URL

    /// Finder's Move to Trash (`FileManager.trashItem(at:resultingItemURL:)`).
    static let system = FileTrasher { url in
        var resulting: NSURL?
        try FileManager.default.trashItem(at: url, resultingItemURL: &resulting)
        guard let resulting else {
            throw CocoaError(.fileNoSuchFile, userInfo: [NSURLErrorKey: url])
        }
        return resulting as URL
    }

    /// A plain folder that stands in for the Trash.
    static func folder(_ folder: URL) -> FileTrasher {
        FileTrasher { url in
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let destination = folder.appendingPathComponent(
                "\(UUID().uuidString)-\(url.lastPathComponent)",
                isDirectory: false
            )
            try FileManager.default.moveItem(at: url, to: destination)
            return destination
        }
    }

    static func temporaryFolder() -> FileTrasher {
        folder(
            FileManager.default.temporaryDirectory
                .appendingPathComponent("Shadowing-Trash-\(UUID().uuidString)", isDirectory: true)
        )
    }
}

/// A file moved to the Trash: where it was, and where the Trash put it.
struct TrashedFile: Equatable, Sendable {
    let original: URL
    let trashed: URL
}

/// A deleted take: its row as it was and its files in the Trash, enough for Undo.
struct TrashedTake: Equatable, Sendable {
    let take: Take
    let files: [TrashedFile]
}

enum TakeTrashError: Error, Equatable, LocalizedError {
    case notInTrash(sequence: Int)
    /// The row could not be inserted or a file could not be moved back; nothing was restored.
    case couldNotRestore(sequence: Int)

    var errorDescription: String? {
        switch self {
        case let .notInTrash(sequence):
            String(localized: "Can't undo: Take \(sequence) is no longer in the Trash.")
        case let .couldNotRestore(sequence):
            String(localized: "Can't undo deleting Take \(sequence).")
        }
    }
}

enum TakeTrash {
    /// Moves the files that exist to the Trash (an old take may have no offset file).
    /// If one move fails, the files already moved are put back and the error is rethrown.
    static func trash(_ urls: [URL], take: Take, using trasher: FileTrasher) throws -> TrashedTake {
        var moved: [TrashedFile] = []
        do {
            for url in urls where FileManager.default.fileExists(atPath: url.path) {
                try moved.append(TrashedFile(original: url, trashed: trasher.moveToTrash(url)))
            }
        } catch {
            putBack(moved)
            throw error
        }
        return TrashedTake(take: take, files: moved)
    }

    /// Throws `notInTrash` when a file is gone (the Trash was emptied).
    static func checkStillInTrash(_ trashed: TrashedTake) throws {
        let manager = FileManager.default
        guard trashed.files.allSatisfy({ manager.fileExists(atPath: $0.trashed.path) }) else {
            throw TakeTrashError.notInTrash(sequence: trashed.take.sequence)
        }
    }

    /// Moves every file back. Throws `notInTrash` without moving anything when a file is gone;
    /// if a move fails, the files already moved go back to the Trash and the error is rethrown.
    static func restore(_ trashed: TrashedTake) throws {
        let manager = FileManager.default
        try checkStillInTrash(trashed)
        var restored: [TrashedFile] = []
        do {
            for file in trashed.files {
                try manager.createDirectory(
                    at: file.original.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try manager.moveItem(at: file.trashed, to: file.original)
                restored.append(file)
            }
        } catch {
            for file in restored.reversed() {
                try? manager.moveItem(at: file.original, to: file.trashed)
            }
            throw error
        }
    }

    private static func putBack(_ files: [TrashedFile]) {
        for file in files.reversed() {
            try? FileManager.default.moveItem(at: file.trashed, to: file.original)
        }
    }
}
