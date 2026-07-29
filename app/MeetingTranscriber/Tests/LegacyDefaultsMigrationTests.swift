@testable import MeetingTranscriber
import XCTest

/// The bundle identifier moved from `com.meetingtranscriber.app` to
/// `app.meetingtranscriber`, and UserDefaults is scoped per identifier — so
/// without this migration every existing user silently loses every setting on
/// the update. The decision of *what* to copy is the part worth testing; the
/// read/write of the two domains is a thin wrapper around Foundation.
final class LegacyDefaultsMigrationTests: XCTestCase {
    func testCopiesLegacyKeysWhenNothingMigratedYet() {
        let plan = LegacyDefaultsMigration.plan(
            legacy: ["whisperLanguage": "de", "autoWatch": true],
            existing: [],
            alreadyMigrated: false,
        )
        XCTAssertEqual(plan["whisperLanguage"] as? String, "de")
        XCTAssertEqual(plan["autoWatch"] as? Bool, true)
    }

    /// A value the user already set under the new identifier is the newer
    /// intent and must win — otherwise a stale legacy plist would keep
    /// overwriting it.
    func testKeysAlreadySetUnderTheNewIdentifierAreNotOverwritten() {
        let plan = LegacyDefaultsMigration.plan(
            legacy: ["whisperLanguage": "de", "autoWatch": true],
            existing: ["whisperLanguage"],
            alreadyMigrated: false,
        )
        XCTAssertNil(plan["whisperLanguage"])
        XCTAssertEqual(plan["autoWatch"] as? Bool, true)
    }

    /// Runs once. Otherwise a user who deliberately reset a setting back to its
    /// default would have the legacy value restored on the next launch.
    func testNothingIsCopiedOnceTheMigrationHasRun() {
        let plan = LegacyDefaultsMigration.plan(
            legacy: ["whisperLanguage": "de"],
            existing: [],
            alreadyMigrated: true,
        )
        XCTAssertTrue(plan.isEmpty)
    }

    func testEmptyLegacyDomainProducesNothingToDo() {
        let plan = LegacyDefaultsMigration.plan(legacy: [:], existing: [], alreadyMigrated: false)
        XCTAssertTrue(plan.isEmpty)
    }

    /// The marker itself lives in the legacy domain too once a user has run a
    /// migrated build and then an older one; copying it across would mark the
    /// new domain as migrated without having copied anything.
    func testTheMigrationMarkerIsNeverCopied() {
        let plan = LegacyDefaultsMigration.plan(
            legacy: [LegacyDefaultsMigration.markerKey: true, "autoWatch": true],
            existing: [],
            alreadyMigrated: false,
        )
        XCTAssertNil(plan[LegacyDefaultsMigration.markerKey])
        XCTAssertEqual(plan["autoWatch"] as? Bool, true)
    }

    // MARK: - end to end against real defaults domains

    func testRunCopiesAcrossDomainsAndIsIdempotent() throws {
        let legacyName = "app.meetingtranscriber.test.legacy.\(UUID().uuidString)"
        let currentName = "app.meetingtranscriber.test.current.\(UUID().uuidString)"
        let legacy = try XCTUnwrap(UserDefaults(suiteName: legacyName))
        let current = try XCTUnwrap(UserDefaults(suiteName: currentName))
        defer {
            legacy.removePersistentDomain(forName: legacyName)
            current.removePersistentDomain(forName: currentName)
        }
        legacy.set("de", forKey: "whisperLanguage")
        legacy.set(true, forKey: "autoWatch")

        LegacyDefaultsMigration.run(into: current, legacyDomain: legacyName)
        XCTAssertEqual(current.string(forKey: "whisperLanguage"), "de")
        XCTAssertTrue(current.bool(forKey: "autoWatch"))
        XCTAssertTrue(current.bool(forKey: LegacyDefaultsMigration.markerKey))

        // Second run must be inert even though the legacy domain still exists:
        // the user's later choice under the new identifier has to survive.
        current.set("en", forKey: "whisperLanguage")
        LegacyDefaultsMigration.run(into: current, legacyDomain: legacyName)
        XCTAssertEqual(current.string(forKey: "whisperLanguage"), "en")
    }
}
