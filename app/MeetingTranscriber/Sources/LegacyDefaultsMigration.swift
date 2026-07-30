import Foundation
import os.log

private let logger = Logger(subsystem: AppPaths.logSubsystem, category: "LegacyDefaultsMigration")

/// One-shot carry-over of the user's settings from the pre-rename bundle
/// identifier. UserDefaults is scoped per identifier, so the move to
/// `app.meetingtranscriber` would otherwise reset every preference on update.
///
/// Copies the legacy domain wholesale rather than an explicit key list:
/// `AppSettings` reads ~50 keys as string literals spread through its
/// initialiser, so a curated list would silently drift out of date and drop
/// exactly the settings nobody remembered to add. The persistent domain is the
/// old app's own plist — global and system-wide domains are not part of it.
///
/// Does nothing in the sandboxed App Store build, which cannot read another
/// identifier's preferences. That variant has no installed base under the old
/// identifier, so there is nothing to carry over.
enum LegacyDefaultsMigration {
    /// What each current identifier was called before the rename.
    ///
    /// A table rather than one constant, because the release and dev builds
    /// each have their own history: pointing both at the release domain made
    /// the dev build inherit the release user's settings on first launch, which
    /// is exactly the separation the dev identity exists to keep.
    private static let legacyDomains = [
        "app.meetingtranscriber": "com.meetingtranscriber.app",
        "app.meetingtranscriber.dev": "com.meetingtranscriber.dev",
    ]

    /// The pre-rename domain for a current identifier, or nil when there is
    /// none. Unknown identifiers get nothing: guessing a domain for one could
    /// only import settings that were never ours.
    static func legacyDomain(for bundleID: String) -> String? {
        legacyDomains[bundleID]
    }

    /// Set once the copy has run, so a later launch never re-applies it.
    static let markerKey = "migratedFromLegacyBundleIdentifier"

    /// Which key/value pairs to write into the current domain: everything from
    /// the legacy domain except the marker and except keys already set under the
    /// new identifier, which are the user's newer intent.
    ///
    /// Running at most once is `run`'s concern, not this function's.
    static func plan(legacy: [String: Any], existing: Set<String>) -> [String: Any] {
        legacy.filter { key, _ in
            key != markerKey && !existing.contains(key)
        }
    }

    /// The two places a bundle identifier's preferences can physically live,
    /// merged into what the old app actually read.
    ///
    /// If a container exists for an identifier, macOS redirects that app's
    /// UserDefaults access into it — including for a binary that is not
    /// sandboxed, which is why `defaults read` on the standard domain can
    /// disagree with what the app sees. The container therefore wins where both
    /// define a key. Normal installs have no container and only pass `standard`.
    static func mergedLegacy(standard: [String: Any], container: [String: Any]) -> [String: Any] {
        standard.merging(container) { _, fromContainer in fromContainer }
    }

    /// The container preferences for a bundle identifier, empty when it has no
    /// container — the normal case, and indistinguishable here from a container
    /// we cannot read (the sandboxed build): both mean "nothing to merge".
    static func containerDefaults(for bundleID: String) -> [String: Any] {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Containers/\(bundleID)")
            .appendingPathComponent("Data/Library/Preferences/\(bundleID).plist")
        guard let data = try? Data(contentsOf: url),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil),
              let dict = plist as? [String: Any]
        else { return [:] }
        return dict
    }

    /// Reads the legacy domain belonging to the running identifier, applies
    /// `plan`, and records that it ran. Marks itself done even when there was
    /// nothing to copy, so the fresh-install case stops re-reading a domain
    /// that will never appear.
    ///
    /// `legacyDomain` is resolved from the running bundle identifier, so the
    /// dev build reads the old dev domain rather than the release user's.
    /// Tests pass it explicitly; outside an app bundle there is no identifier
    /// and nothing to migrate.
    static func run(into defaults: UserDefaults, legacyDomain: String? = nil) {
        guard !defaults.bool(forKey: markerKey) else { return }
        guard let legacyDomain = legacyDomain
            ?? Bundle.main.bundleIdentifier.flatMap(self.legacyDomain(for:))
        else { return }

        let legacy = mergedLegacy(
            standard: defaults.persistentDomain(forName: legacyDomain) ?? [:],
            container: containerDefaults(for: legacyDomain),
        )
        let existing = Set(legacy.keys.filter { defaults.object(forKey: $0) != nil })
        let pending = plan(legacy: legacy, existing: existing)

        for (key, value) in pending {
            defaults.set(value, forKey: key)
        }
        defaults.set(true, forKey: markerKey)
        if !pending.isEmpty {
            logger.info("Carried \(pending.count, privacy: .public) settings over from the previous bundle identifier")
        }
    }
}
