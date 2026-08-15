import Foundation

/// Everything derived from `customOutputDirBookmark`. The bookmark itself has to
/// stay a stored property on the class so `@Observable` can track it; the rest
/// lives here to keep `AppSettings.swift` under its `file_length` budget.
extension AppSettings {
    /// Resolved URL from the security-scoped bookmark, or nil when none is set
    /// or the bookmark no longer resolves. Read-only: security-scoped *access*
    /// is the caller's job — every call site does its own paired
    /// `startAccessingSecurityScopedResource()` / `stopAccessing…`.
    ///
    /// A stale bookmark still resolves, so this deliberately does not repair it.
    /// `body` reads this through `effectiveOutputDir`, and repairing here would
    /// write to observed state from inside a view update. `repairStaleCustomOutputDirBookmark()`
    /// does that once at launch instead.
    var customOutputDir: URL? {
        var isStale = false
        return resolveCustomOutputDir(isStale: &isStale)
    }

    /// The effective output directory: custom choice or ~/Downloads/MeetingTranscriber/.
    var effectiveOutputDir: URL {
        customOutputDir ?? AppPaths.downloadsProtocolsDir
    }

    /// Store a user-selected directory as a security-scoped bookmark.
    func setCustomOutputDir(_ url: URL) {
        guard let data = makeBookmark(for: url) else { return }
        customOutputDirBookmark = data
    }

    /// Clear the custom output directory, reverting to the default.
    func clearCustomOutputDir() {
        customOutputDirBookmark = nil
    }

    /// Re-create the bookmark when macOS reports it stale (the folder moved or
    /// was renamed). Call once at launch, off the view-update path — see the note
    /// on `customOutputDir`. No-op when no bookmark is set or it still resolves.
    func repairStaleCustomOutputDirBookmark() {
        var isStale = false
        guard let url = resolveCustomOutputDir(isStale: &isStale), isStale,
              let refreshed = makeBookmark(for: url)
        else { return }
        customOutputDirBookmark = refreshed
    }

    // MARK: - Helpers

    private func resolveCustomOutputDir(isStale: inout Bool) -> URL? {
        guard let data = customOutputDirBookmark else { return nil }
        return try? URL(
            resolvingBookmarkData: data,
            options: .withSecurityScope,
            relativeTo: nil,
            bookmarkDataIsStale: &isStale,
        )
    }

    private func makeBookmark(for url: URL) -> Data? {
        try? url.bookmarkData(
            options: .withSecurityScope,
            includingResourceValuesForKeys: nil,
            relativeTo: nil,
        )
    }
}
