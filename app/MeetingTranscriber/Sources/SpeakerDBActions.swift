#if !APPSTORE
    import Foundation

    // MARK: - Speaker DB action types

    enum SpeakerActionOutcome: String {
        case ok
        case noop
        case merged
        case notFound
        case invalid
        /// The speaker DB could not be read or written, so nothing changed.
        /// Not `notFound`: a DB that was never read says nothing about whether
        /// the speaker is in it.
        case notSaved
        /// The speaker DB was damaged, set aside and replaced by the profiles
        /// that could still be read (none, if it did not decode at all), and
        /// the action found nothing to act on among them. Not `notFound`
        /// either: the name may well be in the set-aside copy.
        case dbReset
    }

    /// Default `.noop` rejects every request so tests and dry-launches can't
    /// accidentally mutate state — wire real closures explicitly when starting.
    /// `@MainActor`-isolated closures so the struct is `Sendable` (every
    /// invocation happens on MainActor anyway — RPC routing is itself
    /// MainActor-bound — so the isolation doesn't change call-site semantics).
    struct SpeakerDBActions {
        let rename: @MainActor (String, String) -> SpeakerActionOutcome
        let delete: @MainActor (String) -> SpeakerActionOutcome
        let merge: @MainActor (String, String) -> SpeakerActionOutcome
        /// Insert a synthetic speaker with a random embedding. Test-only path
        /// — production never calls this.
        let seed: @MainActor (String) -> SpeakerActionOutcome

        static let noop = Self(
            rename: { _, _ in .invalid },
            delete: { _ in .invalid },
            merge: { _, _ in .invalid },
            seed: { _ in .invalid },
        )
    }

#endif
