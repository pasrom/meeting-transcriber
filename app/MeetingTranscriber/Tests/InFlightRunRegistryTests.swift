@testable import MeetingTranscriber
import XCTest

@MainActor
final class InFlightRunRegistryTests: XCTestCase {
    private func mixPath(_ name: String) -> URL {
        URL(fileURLWithPath: "/tmp/\(name).wav")
    }

    func testFirstClaimSucceeds() {
        let registry = InFlightRunRegistry()
        XCTAssertEqual(registry.begin(jobID: UUID(), mixPath: mixPath("a")), .claimed)
    }

    /// The two refusals are not interchangeable: one says somebody will report
    /// under this very job ID, the other says nobody ever will.
    func testASecondClaimOnTheSameJobNamesTheJobAsTheReason() {
        let registry = InFlightRunRegistry()
        let jobID = UUID()
        XCTAssertEqual(registry.begin(jobID: jobID, mixPath: mixPath("a")), .claimed)
        XCTAssertEqual(registry.begin(jobID: jobID, mixPath: mixPath("a")), .refusedSameJob)
    }

    /// Orphan recovery rebuilds a dropped recording under a fresh job ID, so the
    /// audio path is the second identity a claim has to cover.
    func testAClaimOnAudioHeldByAnotherJobNamesTheAudioAsTheReason() {
        let registry = InFlightRunRegistry()
        XCTAssertEqual(registry.begin(jobID: UUID(), mixPath: mixPath("shared")), .claimed)
        XCTAssertEqual(registry.begin(jobID: UUID(), mixPath: mixPath("shared")), .refusedSameAudio)
    }

    /// Paired imports carry no mix file, so those claims rest on the job ID
    /// alone and must not collide with each other through a shared nil.
    func testClaimsWithoutAudioDoNotBlockEachOther() {
        let registry = InFlightRunRegistry()
        XCTAssertEqual(registry.begin(jobID: UUID(), mixPath: nil), .claimed)
        XCTAssertEqual(registry.begin(jobID: UUID(), mixPath: nil), .claimed)
    }

    func testEndingAClaimReleasesBothIdentities() {
        let registry = InFlightRunRegistry()
        let jobID = UUID()
        XCTAssertEqual(registry.begin(jobID: jobID, mixPath: mixPath("a")), .claimed)
        registry.end(jobID: jobID)
        XCTAssertEqual(registry.begin(jobID: jobID, mixPath: mixPath("a")), .claimed)
        registry.end(jobID: jobID)
        XCTAssertEqual(registry.begin(jobID: UUID(), mixPath: mixPath("a")), .claimed)
    }

    /// Ending a claim the registry never had must not free somebody else's.
    func testEndingAnUnknownClaimLeavesALiveOneAlone() {
        let registry = InFlightRunRegistry()
        let live = UUID()
        XCTAssertEqual(registry.begin(jobID: live, mixPath: mixPath("a")), .claimed)
        registry.end(jobID: UUID())
        XCTAssertEqual(registry.begin(jobID: live, mixPath: mixPath("a")), .refusedSameJob)
    }

    /// The release names only the job, so it cannot disagree with the claim
    /// about which audio to free. Pins that a run holding audio releases it
    /// without the caller repeating the path.
    func testTheReleaseFreesTheAudioWithoutBeingToldWhichItWas() {
        let registry = InFlightRunRegistry()
        let jobID = UUID()
        XCTAssertEqual(registry.begin(jobID: jobID, mixPath: mixPath("held")), .claimed)
        registry.end(jobID: jobID)
        XCTAssertFalse(registry.isInFlight(mixPath: mixPath("held")))
        XCTAssertTrue(registry.claimedAudioPaths.isEmpty)
    }

    /// The queue asks by identity when filtering a restored snapshot and the
    /// orphan scan, so both lookups have to answer independently of a claim.
    func testLookupsReportWhatIsClaimed() {
        let registry = InFlightRunRegistry()
        let jobID = UUID()
        XCTAssertFalse(registry.isInFlight(jobID: jobID))
        XCTAssertFalse(registry.isInFlight(mixPath: mixPath("a")))
        _ = registry.begin(jobID: jobID, mixPath: mixPath("a"))
        XCTAssertTrue(registry.isInFlight(jobID: jobID))
        XCTAssertTrue(registry.isInFlight(mixPath: mixPath("a")))
    }

    /// The orphan scan compares standardized paths, so the registry has to
    /// recognise the same file reached by a different spelling.
    func testTheSameFileSpelledDifferentlyIsOneClaim() {
        let registry = InFlightRunRegistry()
        let claim = registry.begin(jobID: UUID(), mixPath: URL(fileURLWithPath: "/tmp/sub/../call.wav"))
        XCTAssertEqual(claim, .claimed)
        XCTAssertTrue(registry.isInFlight(mixPath: URL(fileURLWithPath: "/tmp/call.wav")))
    }
}
