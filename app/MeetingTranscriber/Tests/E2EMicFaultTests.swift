#if E2E_FAULT_INJECTION
    import AudioTapLib
    @testable import MeetingTranscriber
    import XCTest

    /// Which microphone fault the fault-injection build injects, chosen per
    /// launch by the e2e lane. The whole file exists only in that build, like
    /// the type it tests; run it with
    /// `swift test -Xswiftc -DE2E_FAULT_INJECTION --filter E2EMicFaultTests`.
    final class E2EMicFaultTests: XCTestCase {
        private let key = E2EMicFault.environmentKey

        /// Unset injects nothing. The fault build stays deployed at the shared
        /// dev path after a lane, and a launch that names no fault, a
        /// developer's own, must not get one.
        func testUnsetInjectsNothing() {
            XCTAssertNil(E2EMicFault.fault(from: [:]))
        }

        /// The mic-device-change lane asks for its fault by name.
        func testDeviceChangeIsTheTapInstallFault() throws {
            let fault = try XCTUnwrap(E2EMicFault.fault(from: [key: "device-change"]))
            XCTAssertEqual(fault.triggerRestartAfter, 2)
            XCTAssertNil(fault.withholdBuffersAfter)
        }

        func testStallWithholdsEveryBufferFromTheStartAndArmsNoDeviceChange() throws {
            let fault = try XCTUnwrap(E2EMicFault.fault(from: [key: "stall"]))
            XCTAssertEqual(fault.withholdBuffersAfter, 0)
            XCTAssertNil(fault.triggerRestartAfter, "a device-change restart would reset the watchdog's epochs")
        }

        func testStallAfterDeliveryDeliversFirstThenWithholds() throws {
            let fault = try XCTUnwrap(E2EMicFault.fault(from: [key: "stall-after-delivery"]))
            XCTAssertEqual(fault.withholdBuffersAfter, E2EMicFault.deliverySecondsBeforeStall)
            XCTAssertGreaterThan(E2EMicFault.deliverySecondsBeforeStall, 0)
            XCTAssertNil(fault.triggerRestartAfter)
        }

        /// A typo must not quietly run another fault: the lane would then
        /// measure something it did not ask for.
        func testAnUnknownValueInjectsNothing() {
            XCTAssertNil(E2EMicFault.fault(from: [key: "stal"]))
        }
    }
#endif
