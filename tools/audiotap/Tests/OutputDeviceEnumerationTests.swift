@testable import AudioTapLib
import CoreAudio
import XCTest

/// Tolerant smoke tests for the CoreAudio side of the anchor decision. The
/// device set on a CI runner varies (BlackHole-only, headless), so these verify
/// shape and the invariant the policy depends on rather than a specific device.
final class OutputDeviceEnumerationTests: XCTestCase {
    func testOutputDevicesHaveNonEmptyUIDs() {
        for device in OutputDeviceEnumeration.outputDevices() {
            XCTAssertFalse(device.uid.isEmpty)
            XCTAssertFalse(device.name.isEmpty)
        }
    }

    func testDefaultOutputDeviceShape() {
        guard let device = OutputDeviceEnumeration.defaultOutputDevice() else { return }
        XCTAssertFalse(device.uid.isEmpty)
    }

    /// The policy looks the default up in this list to decide whether a
    /// remembered device is still present, so the two queries have to agree
    /// about what a device's UID is.
    func testDefaultOutputDeviceAppearsInTheEnumeratedList() {
        guard let device = OutputDeviceEnumeration.defaultOutputDevice() else { return }
        let uids = OutputDeviceEnumeration.outputDevices().map(\.uid)
        // A runner with no audio hardware at all enumerates nothing; there is
        // then no disagreement to catch.
        guard !uids.isEmpty else { return }
        XCTAssertTrue(uids.contains(device.uid))
    }

    func testTransportLabelNamesKnownTransports() {
        XCTAssertEqual(OutputDeviceEnumeration.transportLabel(kAudioDeviceTransportTypeVirtual), "Virtual")
        XCTAssertEqual(OutputDeviceEnumeration.transportLabel(kAudioDeviceTransportTypeBuiltIn), "Built-In")
    }

    func testTransportLabelFallsBackToTheRawValue() {
        XCTAssertEqual(OutputDeviceEnumeration.transportLabel(0xDEAD_BEEF), "Unknown(3735928559)")
    }
}
