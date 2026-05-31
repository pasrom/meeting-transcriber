import Foundation

extension FileManager {
    /// POSIX mode for owner-only read/write (`rw-------`). Single source of
    /// truth for the sensitive-file permission constant so every writer
    /// agrees and the value can't drift between call sites.
    static let ownerOnlyPermissions = 0o600

    /// Restrict an already-written file to owner-only read/write (mode 0600),
    /// clearing the world/group-readable bits that a plain `.write(to:)`
    /// inherits from the process umask (typically 0644).
    ///
    /// Call this *after* the file is written. For atomic writes (temp-file +
    /// rename) the rename does not preserve a chmod applied to the staging
    /// file, so the permissions must be set on the final path once it exists.
    ///
    /// Used for biometric-adjacent voice embeddings (`speakers.json`),
    /// transcripts, protocol markdown, naming/sidecar JSON, and pipeline
    /// logs — none of which should be readable by other local users on a
    /// shared Mac. Mirrors the 0600 treatment already applied to audio
    /// captures and the recognition log.
    func restrictToOwner(_ url: URL) throws {
        try setAttributes(
            [.posixPermissions: Self.ownerOnlyPermissions],
            ofItemAtPath: url.path,
        )
    }
}
