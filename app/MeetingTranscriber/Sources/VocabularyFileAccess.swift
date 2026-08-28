import Foundation

/// Resolves persisted sandbox access for terminology files and brackets each
/// read with the matching security scope. Plain paths remain supported for
/// existing non-sandbox installations that predate bookmarks.
enum VocabularyFileAccess {
    static func resolve(path: String, bookmark: Data?) -> URL? {
        if let bookmark {
            var stale = false
            guard let url = try? URL(
                resolvingBookmarkData: bookmark,
                options: .withSecurityScope,
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

    static func withAccess<Result>(to url: URL, _ body: (URL) -> Result) -> Result {
        let accessing = url.startAccessingSecurityScopedResource()
        defer {
            if accessing { url.stopAccessingSecurityScopedResource() }
        }
        return body(url)
    }
}
