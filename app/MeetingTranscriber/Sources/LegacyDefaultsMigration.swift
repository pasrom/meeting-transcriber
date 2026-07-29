import Foundation
import os.log

private let logger = Logger(subsystem: AppPaths.logSubsystem, category: "LegacyDefaultsMigration")

/// One-shot carry-over of the user's settings from the pre-rename bundle
/// identifier. UserDefaults is scoped per identifier, so the move to
/// `app.meetingtranscriber` would otherwise reset every preference on update.
///
/// Copies the legacy *persistent domain* wholesale rather than an explicit key
/// list: `AppSettings` reads ~50 keys as string literals spread through its
/// initialiser, so a curated list would silently drift out of date and drop
/// exactly the settings nobody remembered to add. The persistent domain is the
/// old app's own plist — global and system-wide domains are not part of it.
///
/// Does nothing in the sandboxed App Store build, which cannot read another
/// identifier's preferences. That variant has no installed base under the old
/// identifier, so there is nothing to carry over.
enum LegacyDefaultsMigration {
    /// The identifier the app shipped under until the rename.
    static let defaultLegacyDomain = "com.meetingtranscriber.app"

    /// Set once the copy has run, so a later launch never re-applies it.
    static let markerKey = "migratedFromLegacyBundleIdentifier"

    /// Which key/value pairs to write into the current domain.
    ///
    /// - A key already present under the new identifier is the user's newer
    ///   intent and is left alone.
    /// - Runs exactly once: after that, a value the user reset back to its
    ///   default must not be resurrected from the legacy plist.
    static func plan(
        legacy: [String: Any],
        existing: Set<String>,
        alreadyMigrated: Bool,
    ) -> [String: Any] {
        guard !alreadyMigrated else { return [:] }
        return legacy.filter { key, _ in
            key != markerKey && !existing.contains(key)
        }
    }

    /// Reads the legacy domain, applies `plan`, and records that it ran. Marks
    /// itself done even when there was nothing to copy, so the fresh-install
    /// case stops re-reading a domain that will never appear.
    static func run(into defaults: UserDefaults, legacyDomain: String = defaultLegacyDomain) {
        guard !defaults.bool(forKey: markerKey) else { return }

        let legacy = defaults.persistentDomain(forName: legacyDomain) ?? [:]
        let existing = Set(legacy.keys.filter { defaults.object(forKey: $0) != nil })
        let pending = plan(legacy: legacy, existing: existing, alreadyMigrated: false)

        for (key, value) in pending {
            defaults.set(value, forKey: key)
        }
        defaults.set(true, forKey: markerKey)
        if !pending.isEmpty {
            logger.info("Carried \(pending.count, privacy: .public) settings over from the previous bundle identifier")
        }
    }
}
