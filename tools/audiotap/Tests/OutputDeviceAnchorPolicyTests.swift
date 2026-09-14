@testable import AudioTapLib
import CoreAudio
import XCTest

/// The candidate ordering that decides where the process tap's aggregate is
/// anchored.
///
/// Organized around the three field cases that must all work, because they are
/// what the previous, transport-based version got wrong: it handled case 3 and
/// broke case 2, and no property of the device distinguishes them.
final class OutputDeviceAnchorPolicyTests: XCTestCase {
    private func device(
        _ uid: String, _ name: String, _ transport: UInt32, running: Bool = false,
    ) -> OutputDeviceAnchorPolicy.Device {
        OutputDeviceAnchorPolicy.Device(
            uid: uid, name: name, transportType: transport, isRunningIO: running,
        )
    }

    private var airPods: OutputDeviceAnchorPolicy.Device {
        device("AirPodsPro3-UID", "AirPods Pro 3", kAudioDeviceTransportTypeBluetooth)
    }

    private var builtIn: OutputDeviceAnchorPolicy.Device {
        device("BuiltInSpeakerDevice", "MacBook Pro Speakers", kAudioDeviceTransportTypeBuiltIn)
    }

    /// Teams' own loopback driver — the one that held the default while the
    /// call was rendered elsewhere.
    private var teamsLoopback: OutputDeviceAnchorPolicy.Device {
        device("MSLoopbackDriverDevice_UID", "Microsoft Teams Audio", kAudioDeviceTransportTypeVirtual)
    }

    /// Rogue Amoeba Loopback's device — same transport as the one above, and
    /// the exact opposite situation: meetings recorded through it carried audio
    /// at -25.3, -20.9 and -27.7 dBFS.
    private var studioDisplaySurround: OutputDeviceAnchorPolicy.Device {
        device("StudioDisplaySurround-UID", "Studio Display Surround", kAudioDeviceTransportTypeVirtual)
    }

    private var allDevices: [OutputDeviceAnchorPolicy.Device] {
        [builtIn, airPods, teamsLoopback, studioDisplaySurround]
    }

    // MARK: - Case 1: physical default, app renders there

    func testPhysicalDefaultIsPositionZero() {
        let candidates = OutputDeviceAnchorPolicy.candidates(
            defaultDevice: airPods, outputDevices: allDevices, lastKnownGoodUID: nil,
        )
        XCTAssertEqual(candidates.first, .init(uid: airPods.uid, reason: .systemDefault))
    }

    // MARK: - Case 2: virtual default, app renders INTO it

    /// The regression the transport-based version introduced. A virtual default
    /// must be tried first like any other, because the meeting app most often
    /// follows the system default and renders straight into it.
    func testVirtualDefaultIsStillPositionZero() {
        let candidates = OutputDeviceAnchorPolicy.candidates(
            defaultDevice: studioDisplaySurround, outputDevices: allDevices, lastKnownGoodUID: nil,
        )
        XCTAssertEqual(
            candidates.first, .init(uid: studioDisplaySurround.uid, reason: .systemDefault),
            "a Virtual default must be anchored to, not skipped — this is the Loopback regression",
        )
    }

    /// Even with a physical device already known good, the current default
    /// still leads. Delivery at a previous anchor is not evidence about this one.
    func testVirtualDefaultLeadsEvenWithAKnownGoodPhysicalDevice() {
        let candidates = OutputDeviceAnchorPolicy.candidates(
            defaultDevice: studioDisplaySurround,
            outputDevices: allDevices,
            lastKnownGoodUID: airPods.uid,
        )
        XCTAssertEqual(candidates[0].uid, studioDisplaySurround.uid)
        XCTAssertEqual(candidates[1], .init(uid: airPods.uid, reason: .lastKnownGood))
    }

    // MARK: - Case 3: virtual default, app renders ELSEWHERE

    /// The incident. The default is tried first and will deliver nothing; the
    /// device the tap last received audio from is the very next thing to try.
    func testKnownGoodDeviceFollowsTheDefault() {
        let candidates = OutputDeviceAnchorPolicy.candidates(
            defaultDevice: teamsLoopback,
            outputDevices: allDevices,
            lastKnownGoodUID: airPods.uid,
        )
        XCTAssertEqual(candidates[0], .init(uid: teamsLoopback.uid, reason: .systemDefault))
        XCTAssertEqual(candidates[1], .init(uid: airPods.uid, reason: .lastKnownGood))
    }

    /// Recording started with the virtual device already default, so nothing is
    /// known good yet. Built-in leads the fallbacks: it is the one output that
    /// cannot vanish mid-recording.
    func testBuiltInLeadsTheFallbacksWithNothingKnownGood() {
        let candidates = OutputDeviceAnchorPolicy.candidates(
            defaultDevice: teamsLoopback, outputDevices: allDevices, lastKnownGoodUID: nil,
        )
        XCTAssertEqual(candidates[0].uid, teamsLoopback.uid)
        XCTAssertEqual(candidates[1], .init(uid: builtIn.uid, reason: .builtInFallback))
    }

    // MARK: - List construction

    func testKnownGoodDeviceThatIsGoneIsIgnored() {
        let candidates = OutputDeviceAnchorPolicy.candidates(
            defaultDevice: teamsLoopback,
            outputDevices: [teamsLoopback, builtIn],
            lastKnownGoodUID: airPods.uid,
        )
        XCTAssertFalse(candidates.contains { $0.uid == airPods.uid })
        XCTAssertEqual(candidates[1], .init(uid: builtIn.uid, reason: .builtInFallback))
    }

    /// A device is never offered twice, whatever number of roles it qualifies
    /// for — a repeat would waste a watchdog trip re-proving the same anchor.
    func testNoDeviceAppearsTwice() {
        let candidates = OutputDeviceAnchorPolicy.candidates(
            defaultDevice: builtIn,
            outputDevices: allDevices,
            lastKnownGoodUID: builtIn.uid,
        )
        XCTAssertEqual(Set(candidates.map(\.uid)).count, candidates.count)
        XCTAssertEqual(candidates[0], .init(uid: builtIn.uid, reason: .systemDefault))
    }

    /// The known-good device is offered before the untried hardware even when
    /// it is itself virtual: it has demonstrated delivery, which is the only
    /// evidence this search recognizes.
    func testAKnownGoodVirtualDeviceOutranksUntriedHardware() {
        let candidates = OutputDeviceAnchorPolicy.candidates(
            defaultDevice: teamsLoopback,
            outputDevices: allDevices,
            lastKnownGoodUID: studioDisplaySurround.uid,
        )
        XCTAssertEqual(candidates[1], .init(uid: studioDisplaySurround.uid, reason: .lastKnownGood))
    }

    /// Remaining hardware is still worth trying after built-in, in enumeration
    /// order.
    func testRemainingPhysicalDevicesFollowBuiltIn() {
        let candidates = OutputDeviceAnchorPolicy.candidates(
            defaultDevice: teamsLoopback, outputDevices: allDevices, lastKnownGoodUID: nil,
        )
        XCTAssertEqual(candidates.map(\.uid), [
            teamsLoopback.uid, builtIn.uid, airPods.uid,
        ])
        XCTAssertEqual(candidates.last?.reason, .physicalFallback)
    }

    /// A machine whose every output is virtual has exactly one thing to try,
    /// and no fallback is better than the default.
    func testAllVirtualYieldsOnlyTheDefault() {
        let candidates = OutputDeviceAnchorPolicy.candidates(
            defaultDevice: teamsLoopback,
            outputDevices: [teamsLoopback, studioDisplaySurround],
            lastKnownGoodUID: nil,
        )
        XCTAssertEqual(candidates, [.init(uid: teamsLoopback.uid, reason: .systemDefault)])
    }

    func testEmptyDeviceListStillOffersTheDefault() {
        let candidates = OutputDeviceAnchorPolicy.candidates(
            defaultDevice: teamsLoopback, outputDevices: [], lastKnownGoodUID: nil,
        )
        XCTAssertEqual(candidates, [.init(uid: teamsLoopback.uid, reason: .systemDefault)])
    }

    // MARK: - Transport, in its remaining role

    func testVirtualIsInterposed() {
        XCTAssertTrue(OutputDeviceAnchorPolicy.isInterposed(transportType: kAudioDeviceTransportTypeVirtual))
    }

    /// A user-created multi-output device is a render target the user
    /// configured, so it stays a first-class fallback.
    func testAggregateIsNotInterposed() {
        XCTAssertFalse(OutputDeviceAnchorPolicy.isInterposed(transportType: kAudioDeviceTransportTypeAggregate))
    }

    func testHardwareTransportsAreNotInterposed() {
        for transport in [
            kAudioDeviceTransportTypeBuiltIn,
            kAudioDeviceTransportTypeBluetooth,
            kAudioDeviceTransportTypeUSB,
            kAudioDeviceTransportTypeHDMI,
            kAudioDeviceTransportTypeDisplayPort,
            kAudioDeviceTransportTypeThunderbolt,
            kAudioDeviceTransportTypeAirPlay,
        ] {
            XCTAssertFalse(
                OutputDeviceAnchorPolicy.isInterposed(transportType: transport),
                "transport \(transport) must rank as hardware among the fallbacks",
            )
        }
    }

    /// Transport orders the fallbacks only. A virtual device that is not the
    /// default and is not known good is never offered, because a second
    /// interposed driver is an unlikely place for the audio to have gone.
    func testUntriedVirtualDevicesAreNotOfferedAsFallbacks() {
        let candidates = OutputDeviceAnchorPolicy.candidates(
            defaultDevice: teamsLoopback, outputDevices: allDevices, lastKnownGoodUID: nil,
        )
        XCTAssertFalse(candidates.contains { $0.uid == studioDisplaySurround.uid })
    }

    // MARK: - Running IO

    /// The signal that was missing when two recordings were lost. The meeting
    /// app had stopped playing to the system default and started playing to the
    /// headphones; the search advanced to built-in speakers, where nothing was
    /// playing either.
    func testARunningDeviceLeadsTheFallbacks() {
        let runningAirPods = device(
            "AirPodsPro3-UID", "AirPods Pro 3", kAudioDeviceTransportTypeBluetooth, running: true,
        )
        let candidates = OutputDeviceAnchorPolicy.candidates(
            defaultDevice: teamsLoopback,
            outputDevices: [builtIn, runningAirPods, teamsLoopback],
            lastKnownGoodUID: nil,
        )
        XCTAssertEqual(candidates[0].uid, teamsLoopback.uid)
        XCTAssertEqual(
            candidates[1].uid, runningAirPods.uid,
            "a device with IO running is where the audio actually went",
        )
    }

    /// Position 0 is the zero-regression guarantee and must not be traded away:
    /// a default the app IS rendering into has to behave exactly as it always
    /// did, and the running signal is not clean enough to lead with — on one
    /// measured incident two devices were running at once.
    func testTheSystemDefaultLeadsEvenWhenItIsNotRunningIO() {
        let runningAirPods = device(
            "AirPodsPro3-UID", "AirPods Pro 3", kAudioDeviceTransportTypeBluetooth, running: true,
        )
        let idleDefault = device(
            "StudioDisplaySurround-UID", "Studio Display Surround",
            kAudioDeviceTransportTypeVirtual, running: false,
        )
        let candidates = OutputDeviceAnchorPolicy.candidates(
            defaultDevice: idleDefault,
            outputDevices: [builtIn, runningAirPods, idleDefault],
            lastKnownGoodUID: nil,
        )
        XCTAssertEqual(candidates[0], .init(uid: idleDefault.uid, reason: .systemDefault))
    }

    /// Within each running group the reason ordering still decides, so this is
    /// a stable partition rather than a sort.
    func testRunningPartitionPreservesReasonOrderWithinEachGroup() {
        let runningAirPods = device(
            "AirPodsPro3-UID", "AirPods Pro 3", kAudioDeviceTransportTypeBluetooth, running: true,
        )
        let runningUSB = device(
            "UsbInterface-UID", "Scarlett 2i2", kAudioDeviceTransportTypeUSB, running: true,
        )
        let candidates = OutputDeviceAnchorPolicy.candidates(
            defaultDevice: teamsLoopback,
            outputDevices: [builtIn, runningAirPods, runningUSB, teamsLoopback],
            lastKnownGoodUID: runningUSB.uid,
        )
        // Both are running, so lastKnownGood still outranks untried hardware.
        XCTAssertEqual(candidates[1], .init(uid: runningUSB.uid, reason: .lastKnownGood))
        XCTAssertEqual(candidates[2].uid, runningAirPods.uid)
        XCTAssertEqual(candidates.last?.uid, builtIn.uid, "the idle device sinks to the back")
    }

    func testOrderIsUnchangedWhenNothingReportsRunningIO() {
        let candidates = OutputDeviceAnchorPolicy.candidates(
            defaultDevice: teamsLoopback, outputDevices: allDevices, lastKnownGoodUID: nil,
        )
        XCTAssertEqual(candidates.map(\.uid), [teamsLoopback.uid, builtIn.uid, airPods.uid])
    }

    /// Today's incident, end to end: Teams stopped playing to the system
    /// default and started playing to the AirPods eleven seconds before capture
    /// began. The first fallback must be the AirPods, not built-in speakers.
    func testTodaysIncidentReachesTheDeviceTeamsIsPlayingTo() {
        let idleDefault = device(
            "StudioDisplaySurround-UID", "Studio Display Surround",
            kAudioDeviceTransportTypeVirtual, running: false,
        )
        let runningAirPods = device(
            "20-F4-D4-4D-7F-DF:output", "AirPods Pro 3",
            kAudioDeviceTransportTypeBluetooth, running: true,
        )
        let candidates = OutputDeviceAnchorPolicy.candidates(
            defaultDevice: idleDefault,
            outputDevices: [builtIn, runningAirPods, idleDefault],
            lastKnownGoodUID: nil,
        )
        var search = AnchorSearch()
        XCTAssertEqual(search.selection(from: candidates)?.candidate.uid, idleDefault.uid)

        // The watchdog proves the default dead, and the search advances once.
        XCTAssertTrue(search.advance(candidateCount: candidates.count))
        XCTAssertEqual(
            search.selection(from: candidates)?.candidate.uid, runningAirPods.uid,
            "one advance must reach the device Teams is actually rendering to",
        )
    }
}
