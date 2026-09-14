@testable import AudioTapLib
import CoreAudio
import XCTest

/// The cursor rules: advance only on a proven-dead anchor, reset on a device
/// change, stop at the end of the list, and remember a device as good only when
/// audio genuinely arrived there.
final class AnchorSearchTests: XCTestCase {
    private func candidate(_ uid: String) -> OutputDeviceAnchorPolicy.Candidate {
        OutputDeviceAnchorPolicy.Candidate(uid: uid, reason: .physicalFallback)
    }

    private var threeCandidates: [OutputDeviceAnchorPolicy.Candidate] {
        [candidate("a"), candidate("b"), candidate("c")]
    }

    // MARK: - Selection

    func testSearchStartsAtTheSystemDefault() {
        let search = AnchorSearch()
        XCTAssertEqual(search.cursor, 0)
        XCTAssertEqual(search.selection(from: threeCandidates)?.candidate.uid, "a")
        XCTAssertEqual(search.selection(from: threeCandidates)?.position, 0)
    }

    func testSelectionOfAnEmptyListIsNil() {
        XCTAssertNil(AnchorSearch().selection(from: []))
    }

    /// The candidate list is rebuilt from a live enumeration on every attempt,
    /// so it can legitimately shrink under a cursor that was valid a moment ago
    /// — unplugging an interface mid-search does exactly that.
    func testSelectionClampsWhenTheListShrinks() {
        var search = AnchorSearch()
        XCTAssertTrue(search.advance(candidateCount: 3))
        XCTAssertTrue(search.advance(candidateCount: 3))
        let selection = search.selection(from: [candidate("a")])
        XCTAssertEqual(selection?.candidate.uid, "a")
        XCTAssertEqual(selection?.position, 0)
    }

    // MARK: - Advancing

    func testAdvanceWalksTheListOnce() {
        var search = AnchorSearch()
        XCTAssertTrue(search.advance(candidateCount: 3))
        XCTAssertEqual(search.selection(from: threeCandidates)?.candidate.uid, "b")
        XCTAssertTrue(search.advance(candidateCount: 3))
        XCTAssertEqual(search.selection(from: threeCandidates)?.candidate.uid, "c")
    }

    /// Once every anchor has been proven dead, cycling would only spend more
    /// audio re-proving it.
    func testAdvanceStopsAtTheEndOfTheList() {
        var search = AnchorSearch()
        XCTAssertTrue(search.advance(candidateCount: 3))
        XCTAssertTrue(search.advance(candidateCount: 3))
        XCTAssertFalse(search.advance(candidateCount: 3))
        XCTAssertFalse(search.advance(candidateCount: 3))
        XCTAssertEqual(search.selection(from: threeCandidates)?.position, 2)
    }

    func testASingleCandidateCannotBeAdvancedPast() {
        var search = AnchorSearch()
        XCTAssertFalse(search.advance(candidateCount: 1))
        XCTAssertEqual(search.cursor, 0)
    }

    // MARK: - Reset

    /// Load-bearing: when the meeting app hands the default back to real
    /// hardware, the tap has to follow it there rather than stay parked on the
    /// fallback the previous stretch escaped to.
    func testDeviceChangeReturnsTheSearchToTheDefault() {
        var search = AnchorSearch()
        _ = search.advance(candidateCount: 3)
        _ = search.advance(candidateCount: 3)
        search.resetToDefault()
        XCTAssertEqual(search.selection(from: threeCandidates)?.position, 0)
    }

    /// A reset restores the ability to walk the list again, because a new
    /// default is a genuinely new situation.
    func testResetRestoresTheAbilityToAdvance() {
        var search = AnchorSearch()
        _ = search.advance(candidateCount: 2)
        XCTAssertFalse(search.advance(candidateCount: 2))
        search.resetToDefault()
        XCTAssertTrue(search.advance(candidateCount: 2))
    }

    func testResetDoesNotForgetTheKnownGoodDevice() {
        var search = AnchorSearch()
        search.recordDelivery(at: "airpods")
        search.resetToDefault()
        XCTAssertEqual(search.lastKnownGoodUID, "airpods")
    }

    // MARK: - Known good

    func testNothingIsKnownGoodBeforeAnyDelivery() {
        XCTAssertNil(AnchorSearch().lastKnownGoodUID)
    }

    func testDeliveryRecordsTheAnchor() {
        var search = AnchorSearch()
        search.recordDelivery(at: "airpods")
        XCTAssertEqual(search.lastKnownGoodUID, "airpods")
    }

    /// Called from the buffer path, so repeats on a healthy recording must be
    /// inert.
    func testRepeatedDeliveryAtTheSameAnchorIsIdempotent() {
        var search = AnchorSearch()
        search.recordDelivery(at: "airpods")
        let afterFirst = search
        for _ in 0 ..< 1000 {
            search.recordDelivery(at: "airpods")
        }
        XCTAssertEqual(search, afterFirst)
    }

    func testALaterDeliveryElsewhereReplacesTheKnownGoodDevice() {
        var search = AnchorSearch()
        search.recordDelivery(at: "airpods")
        search.recordDelivery(at: "StudioDisplaySurround-UID")
        XCTAssertEqual(search.lastKnownGoodUID, "StudioDisplaySurround-UID")
    }

    // MARK: - The incident, end to end

    /// Walks the 2026-08-24 recording through policy + search together, driving
    /// only the two events production drives: a delivery credit when audio
    /// arrives, and an advance when the watchdog proves an anchor dead.
    ///
    /// This is the test that would have caught the transport-based version's
    /// regression, because step 2 is Loopback's live virtual device and step 3
    /// is Teams' dead one — the same transport, opposite outcomes.
    func testTheIncidentTimelineEndsWithAudioAtEveryStage() {
        let airPods = OutputDeviceAnchorPolicy.Device(
            uid: "AirPodsPro3-UID", name: "AirPods Pro 3",
            transportType: kAudioDeviceTransportTypeBluetooth,
        )
        let builtIn = OutputDeviceAnchorPolicy.Device(
            uid: "BuiltInSpeakerDevice", name: "MacBook Pro Speakers",
            transportType: kAudioDeviceTransportTypeBuiltIn,
        )
        let teamsLoopback = OutputDeviceAnchorPolicy.Device(
            uid: "MSLoopbackDriverDevice_UID", name: "Microsoft Teams Audio",
            transportType: kAudioDeviceTransportTypeVirtual,
        )
        let devices = [builtIn, airPods, teamsLoopback]
        var search = AnchorSearch()

        func anchor(default def: OutputDeviceAnchorPolicy.Device) -> String {
            let candidates = OutputDeviceAnchorPolicy.candidates(
                defaultDevice: def, outputDevices: devices,
                lastKnownGoodUID: search.lastKnownGoodUID,
            )
            // swiftlint:disable:next force_unwrapping
            let selection = search.selection(from: candidates)!
            return selection.candidate.uid
        }

        // 09:00 — AirPods are the default and the tap delivers there.
        XCTAssertEqual(anchor(default: airPods), airPods.uid)
        search.recordDelivery(at: airPods.uid)

        // 09:12 — Teams makes its loopback driver the default. The device
        // change resets the search, and the default is tried first: the safe
        // guess, and the one that is right whenever the app follows it.
        search.resetToDefault()
        XCTAssertEqual(anchor(default: teamsLoopback), teamsLoopback.uid)

        // It delivers nothing for 120 s, so the watchdog advances the search.
        let duringOutage = OutputDeviceAnchorPolicy.candidates(
            defaultDevice: teamsLoopback, outputDevices: devices,
            lastKnownGoodUID: search.lastKnownGoodUID,
        )
        XCTAssertTrue(search.advance(candidateCount: duringOutage.count))
        XCTAssertEqual(
            anchor(default: teamsLoopback), airPods.uid,
            "the tap must fall back to the device that last delivered audio",
        )
        search.recordDelivery(at: airPods.uid)

        // 09:45 — the default reverts to the AirPods. The reset follows it back.
        search.resetToDefault()
        XCTAssertEqual(anchor(default: airPods), airPods.uid)
    }
}
