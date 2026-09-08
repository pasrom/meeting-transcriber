import Foundation

/// Where output goes right now, and why. `effectiveOutputDir` answers only the
/// first question, and the second is what tells a fallback apart from a choice:
/// `.defaultLocation` and `.fallback` point at the same folder, but one is what
/// the user asked for and the other is standing in for a folder that cannot be
/// reached. `OutputDirectoryResolver` reports the latter; nothing reports the
/// former.
enum OutputDirectoryResolution: Equatable {
    /// No custom folder is configured; the default is the intended destination.
    case defaultLocation(URL)
    /// The chosen folder resolved.
    case custom(URL)
    /// A custom folder is configured but its bookmark does not resolve right
    /// now (an unplugged drive, an unmounted share, a deleted folder), so the
    /// default stands in. `configuredPath` is the path the bookmark was made
    /// for, read from the bookmark bytes, which outlive the folder; nil only
    /// when the bytes themselves are unreadable.
    case fallback(URL, configuredPath: String?)

    /// The directory to use, whichever case applies.
    var url: URL {
        switch self {
        case let .defaultLocation(url), let .custom(url), let .fallback(url, _):
            url
        }
    }
}

/// Everything derived from `customOutputDirBookmark`. The bookmark itself has to
/// stay a stored property on the class so `@Observable` can track it; the rest
/// lives here to keep `AppSettings.swift` under its `file_length` budget.
extension AppSettings {
    /// Where output goes and why. A pure read: it never repairs the bookmark
    /// and never notifies. Views and the launch-time repair read this (through
    /// `effectiveOutputDir`); the two seams that decide a recording's
    /// destination go through `OutputDirectoryResolver`, which adds the
    /// reporting on top.
    var outputDirectoryResolution: OutputDirectoryResolution {
        guard let data = customOutputDirBookmark else { return .defaultLocation(defaultOutputDir) }
        var isStale = false
        if let url = resolveCustomOutputDir(isStale: &isStale) { return .custom(url) }
        return .fallback(defaultOutputDir, configuredPath: Self.configuredPath(in: data))
    }

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
        if case let .custom(url) = outputDirectoryResolution { return url }
        return nil
    }

    /// The effective output directory: the custom choice, or `defaultOutputDir`
    /// when none is chosen or the chosen one cannot be reached. Which of those
    /// two it is: `outputDirectoryResolution`.
    var effectiveOutputDir: URL {
        outputDirectoryResolution.url
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

    /// The path a bookmark was created for, without resolving it. Bookmark data
    /// carries the path it was made from, so this still answers for a folder
    /// that is gone, which is exactly when the answer is needed.
    private static func configuredPath(in bookmark: Data) -> String? {
        URL.resourceValues(forKeys: [.pathKey], fromBookmarkData: bookmark)?.path
    }

    private func makeBookmark(for url: URL) -> Data? {
        try? url.bookmarkData(
            options: .withSecurityScope,
            includingResourceValuesForKeys: nil,
            relativeTo: nil,
        )
    }
}
