@testable import MeetingTranscriber
import XCTest

/// The bundle identifier moved from `com.meetingtranscriber.app` to
/// `app.meetingtranscriber`, and UserDefaults is scoped per identifier — so
/// without this migration every existing user silently loses every setting on
/// the update. The decision of *what* to copy is the part worth testing; the
/// read/write of the two domains is a thin wrapper around Foundation.
final class LegacyDefaultsMigrationTests: XCTestCase {
    func testCopiesLegacyKeys() {
        let plan = LegacyDefaultsMigration.plan(
            legacy: ["whisperLanguage": "de", "autoWatch": true],
            existing: [],
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
        )
        XCTAssertNil(plan["whisperLanguage"])
        XCTAssertEqual(plan["autoWatch"] as? Bool, true)
    }

    /// The marker itself lives in the legacy domain too once a user has run a
    /// migrated build and then an older one; copying it across would mark the
    /// new domain as migrated without having copied anything.
    func testTheMigrationMarkerIsNeverCopied() {
        let plan = LegacyDefaultsMigration.plan(
            legacy: [LegacyDefaultsMigration.markerKey: true, "autoWatch": true],
            existing: [],
        )
        XCTAssertNil(plan[LegacyDefaultsMigration.markerKey])
        XCTAssertEqual(plan["autoWatch"] as? Bool, true)
    }

    // MARK: - container redirect

    /// When a container exists for a bundle identifier, macOS redirects the
    /// app's UserDefaults reads into it — even for a binary that is not
    /// sandboxed. So the values the old app actually saw may live in the
    /// container plist rather than the standard one, and the container has to
    /// win where both define a key. Reading only the standard domain would
    /// migrate stale values, or none, without any sign that it happened.
    func testContainerValuesWinOverTheStandardDomain() {
        let merged = LegacyDefaultsMigration.mergedLegacy(
            standard: ["whisperLanguage": "de", "autoWatch": false],
            container: ["whisperLanguage": "en"],
        )
        XCTAssertEqual(merged["whisperLanguage"] as? String, "en")
        XCTAssertEqual(merged["autoWatch"] as? Bool, false)
    }

    /// The common case: no container, so nothing to merge.
    func testStandardDomainSurvivesWithoutAContainer() {
        let merged = LegacyDefaultsMigration.mergedLegacy(
            standard: ["whisperLanguage": "de"],
            container: [:],
        )
        XCTAssertEqual(merged["whisperLanguage"] as? String, "de")
    }

    func testContainerOnlyKeysAreCarriedOver() {
        let merged = LegacyDefaultsMigration.mergedLegacy(
            standard: [:],
            container: ["micName": "Me"],
        )
        XCTAssertEqual(merged["micName"] as? String, "Me")
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
