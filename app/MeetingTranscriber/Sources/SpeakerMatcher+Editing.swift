import Foundation

/// Rename, delete and merge, for Known Voices and the debug RPC. Each goes
/// through `mutateDB`, so an edit against a DB that could not be used answers
/// `notSaved` rather than a result that reads as done, or as a missing name.
/// One that found the DB damaged answers `replacedCorruptDB` when it found
/// nothing to act on: the DB was copied aside and replaced by the entries that
/// could be salvaged (none, for a file that did not decode at all), so the
/// name may be among the dropped ones, and the file did change. An edit that
/// did find its name among the salvaged entries answers as usual; that
/// already tells callers to refresh.
extension SpeakerMatcher {
    enum RenameResult: Equatable {
        case renamed
        case merged
        case notFound
        case noop
        /// The DB could not be read or written; nothing changed on disk.
        case notSaved
        /// The DB was damaged, copied to this path and replaced by the entries
        /// that could be salvaged. The edit found nothing to act on among them.
        case replacedCorruptDB(URL)
    }

    /// Outcome of `deleteSpeaker` / `mergeSpeakers`.
    enum EditResult: Equatable {
        case applied
        case notFound
        /// The DB could not be read or written; nothing changed on disk. Kept
        /// apart from `notFound`, which a DB that was never read would also
        /// produce although the speaker may well be in it.
        case notSaved
        /// As `RenameResult.replacedCorruptDB`.
        case replacedCorruptDB(URL)
    }

    /// Rename a speaker. If a speaker with `to` already exists, merges `from`
    /// into it. Persists immediately. `noop` covers same-source-and-target;
    /// `notFound` covers a missing source.
    @discardableResult
    func renameSpeaker(from: String, to: String) -> RenameResult {
        guard from != to else { return .noop }
        let mutation = mutateDB { stored -> RenameResult in
            guard let srcIdx = stored.firstIndex(where: { $0.name == from }) else {
                return .notFound
            }
            if let dstIdx = stored.firstIndex(where: { $0.name == to }) {
                stored[dstIdx] = Self.merged(into: stored[dstIdx], from: stored[srcIdx])
                stored.remove(at: srcIdx)
                return .merged
            }
            stored[srcIdx] = stored[srcIdx].renamed(to: to)
            return .renamed
        }
        guard mutation.saved else { return .notSaved }
        if let copiedTo = mutation.resetUnlessFound(mutation.value != .notFound) { return .replacedCorruptDB(copiedTo) }
        return mutation.value
    }

    /// Remove a speaker.
    @discardableResult
    func deleteSpeaker(name: String) -> EditResult {
        let mutation = mutateDB { stored -> Bool in
            guard let idx = stored.firstIndex(where: { $0.name == name }) else { return false }
            stored.remove(at: idx)
            return true
        }
        return Self.editResult(mutation)
    }

    /// Merge `from` into `into`. Embeddings concatenated and FIFO-trimmed,
    /// centroid weighted-averaged, lastUsed/useCount combined. `notFound`
    /// if either name is missing or if `from == into`.
    @discardableResult
    func mergeSpeakers(from: String, into: String) -> EditResult {
        guard from != into else { return .notFound }
        let mutation = mutateDB { stored -> Bool in
            guard let srcIdx = stored.firstIndex(where: { $0.name == from }),
                  let dstIdx = stored.firstIndex(where: { $0.name == into }) else {
                return false
            }
            stored[dstIdx] = Self.merged(into: stored[dstIdx], from: stored[srcIdx])
            stored.removeAll { $0.name == from }
            return true
        }
        return Self.editResult(mutation)
    }

    private static func editResult(_ mutation: Mutation<Bool>) -> EditResult {
        guard mutation.saved else { return .notSaved }
        if let copiedTo = mutation.resetUnlessFound(mutation.value) { return .replacedCorruptDB(copiedTo) }
        return mutation.value ? .applied : .notFound
    }
}
