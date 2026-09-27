import Foundation

/// Opens and closes security-scoped access to a user-picked folder.
///
/// This is the one place the rule is written down: access has to be opened on
/// the URL object that resolved from the security-scoped bookmark, the output
/// folder root, and never on a URL derived from it (`<root>/protocols`) or
/// rebuilt from its path. Apple documents start-access only for "the
/// security-scoped URL" obtained by resolving the bookmark; a derived or
/// rebuilt URL is a different object that carries no scope of its own, so
/// starting access on it opens nothing in the sandboxed build, while appearing
/// to work in the unsandboxed one. While the root is open, the sandbox
/// extension covers the folder recursively, which is what lets I/O on child
/// paths beneath it work.
///
/// `start` and `stop` must be callable from any thread: `PipelineQueue` calls
/// `stop` from its `deinit`, which runs wherever the last reference is
/// released. The Foundation calls behind `live` have no thread requirement.
///
/// A value rather than direct calls so a test can record which URL a scope was
/// opened on and when. Production uses `live`.
struct SecurityScopeAccess: Sendable {
    let start: @Sendable (URL) -> Bool
    let stop: @Sendable (URL) -> Void

    static let live = Self(
        start: { $0.startAccessingSecurityScopedResource() },
        stop: { $0.stopAccessingSecurityScopedResource() },
    )
}
