import Foundation

enum BookmarkStoreError: Error, Equatable, LocalizedError, Sendable {
    case creationFailed(path: String, reason: String)
    case resolutionFailed(reason: String)
    case accessDenied(path: String)

    var errorDescription: String? {
        switch self {
        case let .creationFailed(path, reason):
            String(localized: "Could not save access to \(path): \(reason)")
        case let .resolutionFailed(reason):
            String(localized: "Could not restore access to the selected file: \(reason)")
        case let .accessDenied(path):
            String(localized: "The app no longer has permission to access \(path).")
        }
    }
}

/// Saves and restores access to user-selected files.
///
/// The app currently runs without App Sandbox (ADR-0011), so:
/// - bookmarks are created and resolved without `.withSecurityScope`. A security-scoped bookmark
///   is tied to the code signature that created it, so every unsigned rebuild would otherwise
///   break it. A plain resolve also opens security-scoped bookmarks saved by older builds, and
///   `isStale` is whatever macOS reports;
/// - only when sandboxed are bookmarks created and resolved with `.withSecurityScope`. If that
///   resolve fails, the bookmark is resolved again without it and reported as stale so the caller
///   re-saves it in the current format;
/// - `startAccessingSecurityScopedResource()` returning `false` is not treated as denial. Access
///   only fails when the file exists but cannot be read; a missing file is left to the validator,
///   which reports it as missing.
struct SecurityScopedBookmarkStore: BookmarkStore {
    typealias Resolver = @Sendable (Data, URL.BookmarkResolutionOptions) throws -> ResolvedBookmark
    typealias ReadabilityCheck = @Sendable (URL) -> Bool

    private let usesSecurityScope: Bool
    private let resolver: Resolver
    private let isReadable: ReadabilityCheck

    init(
        usesSecurityScope: Bool = Self.isSandboxed,
        resolver: @escaping Resolver = Self.systemResolve,
        isReadable: @escaping ReadabilityCheck = Self.isReadableOrMissing
    ) {
        self.usesSecurityScope = usesSecurityScope
        self.resolver = resolver
        self.isReadable = isReadable
    }

    /// The sandbox sets this variable for every sandboxed process.
    static var isSandboxed: Bool {
        ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] != nil
    }

    func createBookmark(for url: URL) throws -> Data {
        let options: URL.BookmarkCreationOptions = usesSecurityScope
            ? [.withSecurityScope, .securityScopeAllowOnlyReadAccess]
            : []
        do {
            return try url.bookmarkData(
                options: options,
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
        let startedScope = bookmark.url.startAccessingSecurityScopedResource()
        guard isReadable(bookmark.url) else {
            if startedScope {
                bookmark.url.stopAccessingSecurityScopedResource()
            }
            throw BookmarkStoreError.accessDenied(path: bookmark.url.path)
        }
        return SecurityScopedBookmarkAccess(resolvedBookmark: bookmark, startedScope: startedScope)
    }

    static func isReadableOrMissing(_ url: URL) -> Bool {
        let fileManager = FileManager.default
        return !fileManager.fileExists(atPath: url.path) || fileManager.isReadableFile(atPath: url.path)
    }

    private func resolve(_ data: Data) throws -> ResolvedBookmark {
        guard usesSecurityScope else {
            do {
                return try resolver(data, [.withoutUI])
            } catch {
                // Callers map this to the relocate-file flow.
                throw BookmarkStoreError.resolutionFailed(reason: error.localizedDescription)
            }
        }

        let scopedError: Error
        do {
            return try resolver(data, [.withSecurityScope, .withoutUI])
        } catch {
            scopedError = error
        }

        do {
            let plain = try resolver(data, [.withoutUI])
            // Marked stale so the caller replaces it with a bookmark created the current way.
            return ResolvedBookmark(url: plain.url, isStale: true)
        } catch {
            // Report the original failure; callers map it to the relocate-file flow.
            throw BookmarkStoreError.resolutionFailed(reason: scopedError.localizedDescription)
        }
    }

    static func systemResolve(
        _ data: Data,
        options: URL.BookmarkResolutionOptions
    ) throws -> ResolvedBookmark {
        var isStale = false
        let url = try URL(
            resolvingBookmarkData: data,
            options: options,
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        )
        return ResolvedBookmark(url: url, isStale: isStale)
    }
}

actor SecurityScopedBookmarkAccess: BookmarkAccess {
    nonisolated let resolvedBookmark: ResolvedBookmark
    private let startedScope: Bool
    private var isActive = true

    init(resolvedBookmark: ResolvedBookmark, startedScope: Bool) {
        self.resolvedBookmark = resolvedBookmark
        self.startedScope = startedScope
    }

    func stop() {
        guard isActive else {
            return
        }
        isActive = false
        if startedScope {
            resolvedBookmark.url.stopAccessingSecurityScopedResource()
        }
    }
}
