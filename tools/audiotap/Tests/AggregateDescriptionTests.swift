@testable import AudioTapLib
import CoreAudio
import XCTest

/// The aggregate description is the one part of the HAL bring-up that is pure
/// data, so it is also the one part that can be pinned without hardware. Each
/// key here has a failure mode that is silent rather than loud: a device that
/// shows up in everyone's Sound settings, or one that records nothing at all.
@available(macOS 14.2, *)
final class AggregateDescriptionTests: XCTestCase {
    private func makeDescription() -> [String: Any] {
        AppAudioCapture.aggregateDescription(
            nameTag: "4242", outputUID: "BuiltInSpeakerDevice", tapUUID: "TAP-UUID",
        )
    }

    func testTheDeviceIsPrivateAndAutoStarts() {
        let desc = makeDescription()

        // Not private: the tap's aggregate appears in System Settings > Sound as
        // a selectable device for every app on the machine.
        XCTAssertEqual(desc[kAudioAggregateDeviceIsPrivateKey as String] as? Bool, true)
        // Not auto-starting: the tap exists and delivers nothing, which is the
        // silent-recording failure this project keeps re-diagnosing.
        XCTAssertEqual(desc[kAudioAggregateDeviceTapAutoStartKey as String] as? Bool, true)
    }

    func testItFollowsTheGivenOutputDevice() throws {
        let desc = makeDescription()

        XCTAssertEqual(
            desc[kAudioAggregateDeviceMainSubDeviceKey as String] as? String, "BuiltInSpeakerDevice",
        )
        let subDevices = try XCTUnwrap(
            desc[kAudioAggregateDeviceSubDeviceListKey as String] as? [[String: Any]],
        )
        XCTAssertEqual(subDevices.count, 1)
        XCTAssertEqual(subDevices.first?[kAudioSubDeviceUIDKey as String] as? String, "BuiltInSpeakerDevice")
    }

    func testItCarriesTheTapWithDriftCompensation() throws {
        let desc = makeDescription()

        let taps = try XCTUnwrap(desc[kAudioAggregateDeviceTapListKey as String] as? [[String: Any]])
        XCTAssertEqual(taps.count, 1)
        XCTAssertEqual(taps.first?[kAudioSubTapUIDKey as String] as? String, "TAP-UUID")
        // Without drift compensation the captured stream slowly desynchronises
        // from the mic track, which shows up as speakers talking over each other
        // later in a long recording rather than as an error.
        XCTAssertEqual(taps.first?[kAudioSubTapDriftCompensationKey as String] as? Bool, true)
    }

    func testTheNameIsIdentifiableAndTheUIDIsUniquePerDevice() throws {
        let first = makeDescription()
        let second = makeDescription()

        // The name is how an orphaned aggregate is found in
        // `system_profiler SPAudioDataType` after a crash.
        XCTAssertEqual(first[kAudioAggregateDeviceNameKey as String] as? String, "audiotap-4242")
        // The UID must not repeat: two live aggregates sharing one UID collide in
        // the HAL, and a restart builds the second while the first still exists.
        let firstUID = try XCTUnwrap(first[kAudioAggregateDeviceUIDKey as String] as? String)
        let secondUID = try XCTUnwrap(second[kAudioAggregateDeviceUIDKey as String] as? String)
        XCTAssertNotEqual(firstUID, secondUID)
    }
}
