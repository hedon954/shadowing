import Foundation

enum BookmarkStoreError: Error, Equatable, LocalizedError, Sendable {
    case creationFailed(path: String, reason: String)
    case resolutionFailed(reason: String)
    case accessDenied(path: String)

    var errorDescription: String? {
        switch self {
        case let .creationFailed(path, reason):
            "Could not save access to \(path): \(reason)"
        case let .resolutionFailed(reason):
            "Could not restore access to the selected file: \(reason)"
        case let .accessDenied(path):
            "The app no longer has permission to access \(path)."
        }
    }
}

struct SecurityScopedBookmarkStore: BookmarkStore {
    func createBookmark(for url: URL) throws -> Data {
        do {
            return try url.bookmarkData(
                options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess],
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
        } catch {
            throw BookmarkStoreError.creationFailed(
                path: url.path,
                reason: error.localizedDescription
            )
        }
    }

    func beginAccess(to data: Data) async throws -> any BookmarkAccess {
        let bookmark = try resolve(data)
        guard bookmark.url.startAccessingSecurityScopedResource() else {
            throw BookmarkStoreError.accessDenied(path: bookmark.url.path)
        }
        return SecurityScopedBookmarkAccess(resolvedBookmark: bookmark)
    }

    private func resolve(_ data: Data) throws -> ResolvedBookmark {
        var isStale = false
        do {
            let url = try URL(
                resolvingBookmarkData: data,
                options: [.withSecurityScope, .withoutUI],
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            )
            return ResolvedBookmark(url: url, isStale: isStale)
        } catch {
            throw BookmarkStoreError.resolutionFailed(reason: error.localizedDescription)
        }
    }
}

actor SecurityScopedBookmarkAccess: BookmarkAccess {
    nonisolated let resolvedBookmark: ResolvedBookmark
    private var isActive = true

    init(resolvedBookmark: ResolvedBookmark) {
        self.resolvedBookmark = resolvedBookmark
    }

    func stop() {
        guard isActive else {
            return
        }
        isActive = false
        resolvedBookmark.url.stopAccessingSecurityScopedResource()
    }
}
