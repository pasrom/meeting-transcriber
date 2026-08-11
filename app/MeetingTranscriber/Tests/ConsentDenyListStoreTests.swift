@testable import MeetingTranscriber
import XCTest

/// The persisting adapter. Every other test of the deny list injects the
/// in-memory store, so none of them would notice if this one forgot to write,
/// and a "Never for this app" that does not survive a relaunch is precisely the
/// failure a user would feel.
@MainActor
final class ConsentDenyListStoreTests: XCTestCase {
    /// A defaults suite of its own per test, torn down at the end, so tests
    /// cannot see each other's writes and none of them touch the real domain.
    private func withDefaults(_ body: (UserDefaults) -> Void) {
        let suiteName = "ConsentDenyListStoreTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("could not create defaults suite")
            return
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }
        body(defaults)
    }

    func testFreshInstallDeniesNothing() {
        // The control case for the two round-trips below: without it, a store
        // that always reported "denied" would pass them both.
        withDefaults { defaults in
            let store = ConsentDenyListStore(settings: AppSettings(defaults: defaults))
            XCTAssertEqual(store.denyList.denied, [])
            XCTAssertFalse(store.isDenied("Fjordfox"))
        }
    }

    func testDenialSurvivesAFreshReadOfTheSameDefaults() {
        withDefaults { defaults in
            ConsentDenyListStore(settings: AppSettings(defaults: defaults)).deny("Fjordfox")

            // A second settings object over the same defaults stands in for the
            // next launch: the value has to come back off disk, not out of memory.
            let reloaded = ConsentDenyListStore(settings: AppSettings(defaults: defaults))
            XCTAssertTrue(reloaded.isDenied("Fjordfox"))
        }
    }

    func testRevertSurvivesTooSoASettingsRemoveIsNotUndoneByARelaunch() {
        withDefaults { defaults in
            let store = ConsentDenyListStore(settings: AppSettings(defaults: defaults))
            store.deny("Fjordfox")
            store.deny("Slack")
            store.revert("Fjordfox")

            let reloaded = ConsentDenyListStore(settings: AppSettings(defaults: defaults))
            XCTAssertEqual(reloaded.denyList.denied, ["Slack"])
        }
    }
}
