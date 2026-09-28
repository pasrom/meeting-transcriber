import Foundation

/// Resolves persisted sandbox access for terminology files and brackets each
/// read with the matching security scope. Plain paths remain supported for
/// existing non-sandbox installations that predate bookmarks.
enum VocabularyFileAccess {
    /// Resolution that does not wait for a volume, with the security scope a
    /// sandboxed read needs. `.withoutUI` and
    /// `.withoutMounting` make a bookmark on a detached network share fail at once
    /// instead of blocking the caller while the share is contacted, which is the
    /// only acceptable form for a read on the main actor. Used by the custom
    /// model folder's validation in `AppSettings`, which runs in `init` and on the
    /// view path; the RPC settings snapshot passes its own fail-fast options. A
    /// load itself resolves with the default and may wait; it runs off the view
    /// path and needs the folder, not an answer.
    static let failFastScopedResolution: URL.BookmarkResolutionOptions = [.withSecurityScope, .withoutUI, .withoutMounting]

    static func resolve(
        path: String,
        bookmark: Data?,
        options: URL.BookmarkResolutionOptions = .withSecurityScope,
    ) -> URL? {
        if let bookmark {
            var stale = false
            guard let url = try? URL(
                resolvingBookmarkData: bookmark,
                options: options,
                relativeTo: nil,
                bookmarkDataIsStale: &stale,
            ) else { return nil }
            // A bookmark-backed setting must never fall through to its display
            // path: that path has no sandbox grant. AppSettings refreshes a
            // resolvable stale bookmark while it owns the persisted data.
            return url
        }
        guard !path.isEmpty else { return nil }
        return URL(fileURLWithPath: path)
    }

    static func makeBookmark(for url: URL) -> Data? {
        try? url.bookmarkData(
            options: .withSecurityScope,
            includingResourceValuesForKeys: nil,
            relativeTo: nil,
        )
    }

    /// For a bookmark macOS reports stale (its target moved or was renamed): the
    /// target's current location and a new bookmark for it. Nil while the
    /// bookmark is current, or when it cannot be resolved or re-created.
    static func refreshedStaleBookmark(_ bookmark: Data) -> (url: URL, bookmark: Data)? {
        var isStale = false
        let resolved = try? URL(
            resolvingBookmarkData: bookmark,
            options: .withSecurityScope,
            relativeTo: nil,
            bookmarkDataIsStale: &isStale,
        )
        guard let url = resolved, isStale,
              let refreshed = withAccess(to: url, makeBookmark)
        else { return nil }
        return (url, refreshed)
    }

    static func withAccess<Result>(to url: URL, _ body: (URL) -> Result) -> Result {
        let accessing = url.startAccessingSecurityScopedResource()
        defer {
            if accessing { url.stopAccessingSecurityScopedResource() }
        }
        return body(url)
    }
}
