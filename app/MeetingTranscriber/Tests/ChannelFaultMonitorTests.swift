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

    /// Stalled now, after `count` stalls in the recording.
    private func stalled(_ count: Int = 1) -> MicCaptureStall {
        MicCaptureStall(isActive: true, count: count)
    }

    // MARK: - Wire names

    func testTheWireNamesAreTheOnesTheAutomationApiPromises() {
        // The raw values are the case names, so a Swift rename would change
        // `/state.channelHealth.micFault` without touching anything that looks
        // like an API. This is what makes that a test failure instead.
        XCTAssertEqual(ChannelFault.noBuffers.rawValue, "noBuffers")
        XCTAssertEqual(ChannelFault.digitalSilence.rawValue, "digitalSilence")
        XCTAssertEqual(ChannelFault.gaveUp.rawValue, "gaveUp")
        XCTAssertEqual(ChannelFault.rebuildsExhausted.rawValue, "rebuildsExhausted")
        XCTAssertEqual(ChannelFault.stalled.rawValue, "stalled")
    }

    // MARK: - A microphone that stalled

    func testAStallIsReportedImmediatelyAndOnce() {
        // The capture layer already waited out its own budget before it
        // stalled, so a second window here would only delay the news.
        var monitor = makeMonitor()
        XCTAssertEqual(
            monitor.update(ages: .unknown, gaveUp: false, elapsedSinceStart: 0, corroborated: false, stall: stalled()),
            .stalled,
        )
        XCTAssertNil(monitor.update(ages: .unknown, gaveUp: false, elapsedSinceStart: 600, corroborated: true, stall: stalled()))
    }

    func testWhileStalledNoSilenceIsReported() {
        // The stall message already says the microphone delivers nothing and
        // what brings it back; a silence report during it repeats half of that.
        var monitor = makeMonitor()
        _ = monitor.update(ages: .unknown, gaveUp: false, elapsedSinceStart: 0, corroborated: false, stall: stalled())
        let dead = ChannelSignalAges(secondsSinceLastBuffer: window, secondsSinceLastEnergy: window)
        XCTAssertNil(monitor.update(ages: dead, gaveUp: false, elapsedSinceStart: 600, corroborated: true, stall: stalled()))
    }

    /// The user followed the advice, the microphone came back and stalled
    /// again. That is news again, not a repetition of the first report.
    func testAStallAfterARevivalIsReportedAgain() {
        var monitor = makeMonitor()
        _ = monitor.update(ages: .unknown, gaveUp: false, elapsedSinceStart: 0, corroborated: false, stall: stalled())
        XCTAssertNil(monitor.update(ages: .unknown, gaveUp: false, elapsedSinceStart: 70, corroborated: false))
        XCTAssertEqual(
            monitor.update(ages: .unknown, gaveUp: false, elapsedSinceStart: 140, corroborated: false, stall: stalled(2)),
            .stalled,
        )
    }

    /// The user switched the input, the revived microphone never delivered,
    /// and it stalled again. The stall never cleared in between, but the
    /// remedy the first report gave did not work, and that is news.
    func testAStallAfterARevivalThatNeverDeliveredIsReportedAgain() {
        var monitor = makeMonitor()
        XCTAssertEqual(
            monitor.update(ages: .unknown, gaveUp: false, elapsedSinceStart: 0, corroborated: false, stall: stalled()),
            .stalled,
        )
        XCTAssertNil(monitor.update(ages: .unknown, gaveUp: false, elapsedSinceStart: 70, corroborated: false, stall: stalled()))
        XCTAssertEqual(
            monitor.update(ages: .unknown, gaveUp: false, elapsedSinceStart: 140, corroborated: false, stall: stalled(2)),
            .stalled,
        )
    }

    /// The ages still span the stall when the flag clears, so judging them at
    /// once would report the revived microphone as dead before it had a
    /// chance. The revival gets a full window of its own.
    func testARevivalGetsAFreshWindow() {
        var monitor = makeMonitor()
        _ = monitor.update(ages: .unknown, gaveUp: false, elapsedSinceStart: 0, corroborated: false, stall: stalled())
        let spanningTheStall = ChannelSignalAges(secondsSinceLastBuffer: 200, secondsSinceLastEnergy: 200)
        XCTAssertNil(monitor.update(ages: spanningTheStall, gaveUp: false, elapsedSinceStart: 200, corroborated: true))
        XCTAssertNil(monitor.update(
            ages: spanningTheStall, gaveUp: false, elapsedSinceStart: 200 + window - 1, corroborated: true,
        ))
        XCTAssertEqual(
            monitor.update(ages: spanningTheStall, gaveUp: false, elapsedSinceStart: 200 + window, corroborated: true),
            .noBuffers,
            "a revived microphone that stays dead for a whole window is reported",
        )
    }

    /// A silence report from before the stall does not silence the revived
    /// microphone for the rest of the recording.
    func testASilenceReportBeforeAStallIsReArmedByTheRevival() {
        var monitor = makeMonitor()
        let dead = ChannelSignalAges(secondsSinceLastBuffer: window, secondsSinceLastEnergy: window)
        XCTAssertEqual(monitor.update(ages: dead, gaveUp: false, elapsedSinceStart: 600, corroborated: true), .noBuffers)
        _ = monitor.update(ages: dead, gaveUp: false, elapsedSinceStart: 660, corroborated: true, stall: stalled())
        XCTAssertNil(monitor.update(ages: dead, gaveUp: false, elapsedSinceStart: 700, corroborated: true))
        let stillDead = ChannelSignalAges(secondsSinceLastBuffer: 700, secondsSinceLastEnergy: 700)
        XCTAssertEqual(
            monitor.update(ages: stillDead, gaveUp: false, elapsedSinceStart: 700 + window, corroborated: true),
            .noBuffers,
        )
    }

    /// A revived microphone that delivers only zeroes, a headset's known
    /// failure shape the watchdog counts as delivering, is still reported.
    func testARevivedMicrophoneThatDeliversZeroesIsReported() {
        var monitor = makeMonitor()
        _ = monitor.update(ages: .unknown, gaveUp: false, elapsedSinceStart: 0, corroborated: false, stall: stalled())
        let zeroes = ChannelSignalAges(secondsSinceLastBuffer: 0, secondsSinceLastEnergy: 600)
        XCTAssertNil(monitor.update(ages: zeroes, gaveUp: false, elapsedSinceStart: 600, corroborated: true))
        XCTAssertEqual(
            monitor.update(ages: zeroes, gaveUp: false, elapsedSinceStart: 600 + window, corroborated: true),
            .digitalSilence,
            "once it has had its window",
        )
    }

    func testAStallAfterASilenceReportIsStillReported() {
        // Not a repetition: silence said the microphone stopped, the stall
        // says restarting it did not help and what will.
        var monitor = makeMonitor()
        let dead = ChannelSignalAges(secondsSinceLastBuffer: window, secondsSinceLastEnergy: window)
        XCTAssertEqual(monitor.update(ages: dead, gaveUp: false, elapsedSinceStart: 600, corroborated: true), .noBuffers)
        XCTAssertEqual(
            monitor.update(ages: dead, gaveUp: false, elapsedSinceStart: 601, corroborated: true, stall: stalled()),
            .stalled,
        )
    }

    func testAGiveUpAfterAStallIsStillReported() {
        // A revival can wedge, and that is terminal news the stall could not
        // give. The capture layer ends the stall with the give-up, so that is
        // the pair to feed.
        var monitor = makeMonitor()
        _ = monitor.update(ages: .unknown, gaveUp: false, elapsedSinceStart: 0, corroborated: false, stall: stalled())
        let ended = MicCaptureStall(isActive: false, count: 1)
        XCTAssertEqual(
            monitor.update(ages: .unknown, gaveUp: true, elapsedSinceStart: 10, corroborated: false, stall: ended),
            .gaveUp,
        )
        let dead = ChannelSignalAges(secondsSinceLastBuffer: 600, secondsSinceLastEnergy: 600)
        XCTAssertNil(
            monitor.update(ages: dead, gaveUp: true, elapsedSinceStart: 600, corroborated: true, stall: ended),
            "nothing after the terminal report, the silence included",
        )
    }

    func testAGiveUpReportedWhileStillStalledIsReportedToo() {
        // Not what the capture layer reports, but the give-up is terminal
        // news whatever the stall says beside it.
        var monitor = makeMonitor()
        _ = monitor.update(ages: .unknown, gaveUp: false, elapsedSinceStart: 0, corroborated: false, stall: stalled())
        XCTAssertEqual(
            monitor.update(ages: .unknown, gaveUp: true, elapsedSinceStart: 10, corroborated: false, stall: stalled()),
            .gaveUp,
        )
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
