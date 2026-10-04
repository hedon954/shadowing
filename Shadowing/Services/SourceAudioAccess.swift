import Foundation

/// Opens the practice MP3 through its security-scoped bookmark, read-only.
struct BookmarkedSourceAudio: SourceAudioAccessing {
    let bookmarks: any BookmarkStore

    func fingerprint(bookmark: Data) async throws -> String {
        try await bookmarks.withAccess(to: bookmark) { resolved in
            try Self.sha256(ofFileAt: resolved.url)
        }
    }

    func withAudioFile<Value: Sendable>(
        bookmark: Data,
        _ operation: @Sendable (URL) async throws -> Value
    ) async throws -> Value {
        try await bookmarks.withAccess(to: bookmark) { resolved in
            try await operation(resolved.url)
        }
    }

    /// Maps the file instead of reading it into memory, so long recordings stay cheap.
    static func sha256(ofFileAt url: URL) throws -> String {
        let data = try Data(contentsOf: url, options: .alwaysMapped)
        return ContentHash.sha256(data)
    }
}
