import AudioTapLib
@testable import MeetingTranscriber
import XCTest

/// The decision "this channel is broken", kept apart from "this channel is
/// quiet".
///
/// `ChannelHealthMonitor` answers the second question from levels and drives
/// the menu-bar tint. It cannot answer the first: a microphone whose owner is
/// simply not speaking reads the same as one the system has muted, and both
/// read like a tap that died. This monitor answers it from what the capture
/// layer reports per buffer instead (`ChannelSignalAges`).
final class ChannelFaultMonitorTests: XCTestCase {
    private let window: TimeInterval = 90

    private func makeMonitor() -> ChannelFaultMonitor {
        ChannelFaultMonitor(window: window)
    }

    // MARK: - Wire names

    func testTheWireNamesAreTheOnesTheAutomationApiPromises() {
        // The raw values are the case names, so a Swift rename would change
        // `/state.channelHealth.micFault` without touching anything that looks
        // like an API. This is what makes that a test failure instead.
        XCTAssertEqual(ChannelFault.noBuffers.rawValue, "noBuffers")
        XCTAssertEqual(ChannelFault.digitalSilence.rawValue, "digitalSilence")
        XCTAssertEqual(ChannelFault.gaveUp.rawValue, "gaveUp")
    }

    // MARK: - A channel that gave up

    func testAGiveUpIsReportedImmediately() {
        // Terminal the moment the flag flips, and the remedy is a restart, so
        // making the user wait out a window for news that cannot change is the
        // same defect as not telling them.
        var monitor = makeMonitor()
        XCTAssertEqual(
            monitor.update(ages: .unknown, gaveUp: true, elapsedSinceStart: 0, corroborated: false),
            .gaveUp,
        )
    }

    func testAGiveUpIsReportedOnlyOnce() {
        var monitor = makeMonitor()
        XCTAssertEqual(monitor.update(ages: .unknown, gaveUp: true, elapsedSinceStart: 0, corroborated: false), .gaveUp)
        XCTAssertNil(monitor.update(ages: .unknown, gaveUp: true, elapsedSinceStart: 600, corroborated: true))
    }

    func testAGiveUpSuppressesAnyLaterSilenceReport() {
        // The give-up message already describes this channel and says the one
        // thing the silence message cannot, that it is not coming back.
        var monitor = makeMonitor()
        XCTAssertEqual(monitor.update(ages: .unknown, gaveUp: true, elapsedSinceStart: 0, corroborated: false), .gaveUp)
        let dead = ChannelSignalAges(secondsSinceLastBuffer: window, secondsSinceLastEnergy: window)
        XCTAssertNil(monitor.update(ages: dead, gaveUp: true, elapsedSinceStart: 600, corroborated: true))
    }

    func testAGiveUpAfterASilenceReportIsStillReported() {
        // The other order, and it is not a repetition: the channel was reported
        // as silent, and now there is something new to say, namely that only a
        // restart brings it back.
        var monitor = makeMonitor()
        let dead = ChannelSignalAges(secondsSinceLastBuffer: window, secondsSinceLastEnergy: window)
        XCTAssertEqual(
            monitor.update(ages: dead, gaveUp: false, elapsedSinceStart: 600, corroborated: true),
            .noBuffers,
        )
        XCTAssertEqual(
            monitor.update(ages: dead, gaveUp: true, elapsedSinceStart: 601, corroborated: true),
            .gaveUp,
        )
    }

    // MARK: - Nothing to report

    func testSignalInsideTheWindowIsNoFault() {
        // The whole point of issue #614: a live microphone in a quiet room, or
        // one its owner muted in the meeting app, keeps delivering real
        // buffers. Nothing here is broken.
        var monitor = makeMonitor()
        let ages = ChannelSignalAges(secondsSinceLastBuffer: 0.05, secondsSinceLastEnergy: 10)
        XCTAssertNil(monitor.update(ages: ages, gaveUp: false, elapsedSinceStart: 300, corroborated: true))
    }

    func testNothingIsReportedBeforeTheWindowCanHavePassed() {
        // A recording that started ten seconds ago has not yet had time to show
        // a ninety-second outage, whatever the ages say.
        var monitor = makeMonitor()
        XCTAssertNil(monitor.update(ages: .unknown, gaveUp: false, elapsedSinceStart: 10, corroborated: true))
    }

    // MARK: - No buffers at all

    func testAChannelThatNeverDeliveredAnyBufferIsReported() {
        var monitor = makeMonitor()
        XCTAssertEqual(
            monitor.update(ages: .unknown, gaveUp: false, elapsedSinceStart: window, corroborated: true),
            .noBuffers,
        )
    }

    func testAChannelWhoseBuffersStoppedIsReported() {
        var monitor = makeMonitor()
        let ages = ChannelSignalAges(secondsSinceLastBuffer: window, secondsSinceLastEnergy: window)
        XCTAssertEqual(monitor.update(ages: ages, gaveUp: false, elapsedSinceStart: 600, corroborated: true), .noBuffers)
    }

    func testAStoppedTransportIsReportedWithoutCorroboration() {
        // Buffers stopping is unambiguous. Unlike digital silence it has no
        // innocent reading, so it does not wait for the other channel to prove
        // that anything was going on.
        var monitor = makeMonitor()
        let ages = ChannelSignalAges(secondsSinceLastBuffer: window, secondsSinceLastEnergy: window)
        XCTAssertEqual(monitor.update(ages: ages, gaveUp: false, elapsedSinceStart: 600, corroborated: false), .noBuffers)
    }

    // MARK: - Buffers of digital silence

    func testBuffersCarryingNothingButZeroesAreReported() {
        // The device or the system muted the channel: the transport is fine,
        // the samples are not.
        var monitor = makeMonitor()
        let ages = ChannelSignalAges(secondsSinceLastBuffer: 0.05, secondsSinceLastEnergy: window)
        XCTAssertEqual(monitor.update(ages: ages, gaveUp: false, elapsedSinceStart: 600, corroborated: true), .digitalSilence)
    }

    func testAChannelSilentSinceTheFirstBufferIsReported() {
        // Muted before the recording began: there is no last-energy instant, so
        // the age of the recording stands in for it.
        var monitor = makeMonitor()
        let ages = ChannelSignalAges(secondsSinceLastBuffer: 0.05, secondsSinceLastEnergy: nil)
        XCTAssertEqual(monitor.update(ages: ages, gaveUp: false, elapsedSinceStart: window, corroborated: true), .digitalSilence)
    }

    func testDigitalSilenceWaitsForCorroboration() {
        // Zeroes are the normal state of a channel with nothing to carry: the
        // far side of a call where nobody is speaking sounds exactly like a tap
        // that lost its permission. Without evidence that the recording was
        // capturing anything at all, this belongs to the symmetric-silence
        // monitor, not here.
        var monitor = makeMonitor()
        let ages = ChannelSignalAges(secondsSinceLastBuffer: 0.05, secondsSinceLastEnergy: window)
        XCTAssertNil(monitor.update(ages: ages, gaveUp: false, elapsedSinceStart: 600, corroborated: false))
    }

    func testCorroborationArrivingLaterStillReports() {
        var monitor = makeMonitor()
        let ages = ChannelSignalAges(secondsSinceLastBuffer: 0.05, secondsSinceLastEnergy: window)
        XCTAssertNil(monitor.update(ages: ages, gaveUp: false, elapsedSinceStart: 600, corroborated: false))
        XCTAssertEqual(monitor.update(ages: ages, gaveUp: false, elapsedSinceStart: 601, corroborated: true), .digitalSilence)
    }

    // MARK: - One report per recording

    func testAFaultIsReportedOnlyOnce() {
        var monitor = makeMonitor()
        let ages = ChannelSignalAges(secondsSinceLastBuffer: 0.05, secondsSinceLastEnergy: window)
        XCTAssertEqual(monitor.update(ages: ages, gaveUp: false, elapsedSinceStart: 600, corroborated: true), .digitalSilence)
        XCTAssertNil(monitor.update(ages: ages, gaveUp: false, elapsedSinceStart: 601, corroborated: true))
        XCTAssertNil(monitor.update(ages: ages, gaveUp: false, elapsedSinceStart: 900, corroborated: true))
    }

    func testASecondKindOfFaultDoesNotReopenTheReport() {
        // Escalating from muted samples to no samples at all is the same
        // channel failing, and the user has already been told about it.
        var monitor = makeMonitor()
        let muted = ChannelSignalAges(secondsSinceLastBuffer: 0.05, secondsSinceLastEnergy: window)
        XCTAssertEqual(monitor.update(ages: muted, gaveUp: false, elapsedSinceStart: 600, corroborated: true), .digitalSilence)
        let dead = ChannelSignalAges(secondsSinceLastBuffer: window, secondsSinceLastEnergy: window)
        XCTAssertNil(monitor.update(ages: dead, gaveUp: false, elapsedSinceStart: 700, corroborated: true))
    }

    func testResetLetsTheNextRecordingReportAgain() {
        var monitor = makeMonitor()
        let ages = ChannelSignalAges(secondsSinceLastBuffer: window, secondsSinceLastEnergy: window)
        XCTAssertEqual(monitor.update(ages: ages, gaveUp: false, elapsedSinceStart: 600, corroborated: true), .noBuffers)
        monitor.reset()
        XCTAssertEqual(monitor.update(ages: ages, gaveUp: false, elapsedSinceStart: 600, corroborated: true), .noBuffers)
    }

    // MARK: - Precedence

    func testAStoppedTransportOutranksItsOwnDigitalSilence() {
        // Buffers that stopped are also buffers that carry no energy. The
        // message has to name the failure the user can act on.
        var monitor = makeMonitor()
        let ages = ChannelSignalAges(secondsSinceLastBuffer: window + 10, secondsSinceLastEnergy: window + 10)
        XCTAssertEqual(monitor.update(ages: ages, gaveUp: false, elapsedSinceStart: 600, corroborated: true), .noBuffers)
    }
}
