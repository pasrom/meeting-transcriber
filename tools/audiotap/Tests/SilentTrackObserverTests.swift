@testable import AudioTapLib
import XCTest

/// Shared with `SilentTrackDiagnosticsTests`. `buffer` defaults to a fresh one
/// because almost every case here is about the energy age; the two that are
/// about the buffer age say so by passing it.
func ages(energy: Double?, buffer: Double? = 0.01) -> ChannelSignalAges {
    ChannelSignalAges(secondsSinceLastBuffer: buffer, secondsSinceLastEnergy: energy)
}

/// `SilentTrackObserver` decides when the app track has entered and left a run
/// of exact zeros while buffers keep arriving (issue #672). Pure, so the bulk of
/// the assertions live here rather than against a live tap.
final class SilentTrackObserverTests: XCTestCase {
    // MARK: - The signature it exists to find

    func testAChannelThatCarriedAudioAndWentToZerosEntersARun() {
        var observer = SilentTrackObserver()
        XCTAssertNil(observer.observe(ages(energy: 0.5)))
        XCTAssertNil(observer.observe(ages(energy: 9.0)), "not yet past the threshold")
        XCTAssertEqual(
            observer.observe(ages(energy: 11.0)),
            .enteredZeroRun(afterSignalSeconds: 11.0),
        )
        XCTAssertTrue(observer.inZeroRun)
        XCTAssertEqual(observer.zeroRuns, 1)
    }

    func testTheRunIsReportedOnceWhileItLasts() {
        var observer = SilentTrackObserver()
        _ = observer.observe(ages(energy: 11.0))
        for energy in stride(from: 16.0, through: 120.0, by: 5.0) {
            XCTAssertNil(
                observer.observe(ages(energy: energy)),
                "a run in progress is not an edge",
            )
        }
        XCTAssertEqual(observer.zeroRuns, 1)
    }

    func testSignalComingBackLeavesTheRunAndReportsItsLength() {
        var observer = SilentTrackObserver()
        _ = observer.observe(ages(energy: 11.0))
        _ = observer.observe(ages(energy: 40.0))
        XCTAssertEqual(
            observer.observe(ages(energy: 0.02)),
            .exitedZeroRun(durationSeconds: 40.0),
            "the run's length is the last age seen inside it, not the age at the exit",
        )
        XCTAssertFalse(observer.inZeroRun)
        XCTAssertEqual(observer.longestZeroRun, 40.0)
    }

    func testTheLongestRunSurvivesLaterShorterOnes() {
        var observer = SilentTrackObserver()
        _ = observer.observe(ages(energy: 60.0))
        _ = observer.observe(ages(energy: 0.02))
        _ = observer.observe(ages(energy: 12.0))
        _ = observer.observe(ages(energy: 0.02))
        XCTAssertEqual(observer.longestZeroRun, 60.0)
        XCTAssertEqual(observer.zeroRuns, 2)
    }

    // MARK: - The two failures it must not claim

    func testAChannelSilentSinceTheFirstBufferIsNeverAnEdge() {
        // Zeroes from the very first buffer is the signature of a tap that was
        // never allowed to hear the app (issue #524). It is a different failure
        // with a different fix, and reporting it here would bury the one this
        // observer is for. The one-off reading it does get (below) is not an
        // edge: it opens no run and counts toward nothing the stop summary
        // reports.
        var observer = SilentTrackObserver()
        for _ in 0 ..< 2 * SilentTrackObserver.silentSinceFirstBufferTicks {
            _ = observer.observe(ages(energy: nil))
        }
        XCTAssertEqual(observer.zeroRuns, 0)
        XCTAssertFalse(observer.inZeroRun)
    }

    // MARK: - A track that never carried signal (issue #671)

    func testATrackSilentSinceTheFirstBufferIsReadOnceAfterAMinute() {
        // The zero-run edge needs signal first, so a track at zeros from its
        // first buffer would otherwise never be read mid-call.
        var observer = SilentTrackObserver()
        let ticks = SilentTrackObserver.silentSinceFirstBufferTicks
        for tick in 1 ..< ticks {
            XCTAssertNil(observer.observe(ages(energy: nil)), "tick \(tick)")
        }
        XCTAssertEqual(observer.observe(ages(energy: nil)), .silentSinceFirstBuffer)
        for tick in 0 ..< ticks {
            XCTAssertNil(observer.observe(ages(energy: nil)), "once per recording, tick \(tick)")
        }
        XCTAssertEqual(observer.edges, 0, "not an edge: it must not spend the edge cap")
    }

    func testSignalArrivingAfterItStillOpensAZeroRun() {
        // The reading changes nothing for the edges: a track that goes quiet
        // after its late first signal is still the zero-run case.
        var observer = SilentTrackObserver()
        for _ in 0 ..< SilentTrackObserver.silentSinceFirstBufferTicks {
            _ = observer.observe(ages(energy: nil))
        }
        XCTAssertNil(observer.observe(ages(energy: 0.5)))
        XCTAssertEqual(observer.observe(ages(energy: 15)), .enteredZeroRun(afterSignalSeconds: 15))
        XCTAssertEqual(observer.zeroRuns, 1)
    }

    func testAnOpenZeroRunIsNeverMisreadAsSilentSinceTheFirstBuffer() {
        // The publisher's energy stamp never resets, so an open run never sees
        // a nil energy age today; the observer still must not count such ticks
        // toward the one-off reading, or a track that carried signal would be
        // logged as silent since its first buffer.
        var observer = SilentTrackObserver()
        _ = observer.observe(ages(energy: 0.5))
        XCTAssertEqual(observer.observe(ages(energy: 15)), .enteredZeroRun(afterSignalSeconds: 15))
        for _ in 0 ..< 2 * SilentTrackObserver.silentSinceFirstBufferTicks {
            XCTAssertNil(observer.observe(ages(energy: nil)))
        }
        XCTAssertTrue(observer.inZeroRun)
    }

    func testOnlyTicksWithBuffersArrivingCountTowardIt() {
        // No buffers is `noBuffers` and has probes of its own (issue #693).
        var observer = SilentTrackObserver()
        let ticks = SilentTrackObserver.silentSinceFirstBufferTicks
        for _ in 0 ..< ticks {
            XCTAssertNil(observer.observe(ages(energy: nil, buffer: nil)))
            XCTAssertNil(observer.observe(ages(energy: nil, buffer: 30)))
        }
        for _ in 1 ..< ticks {
            XCTAssertNil(observer.observe(ages(energy: nil)))
        }
        XCTAssertEqual(observer.observe(ages(energy: nil)), .silentSinceFirstBuffer)
    }

    func testATrackThatCarriedSignalNeverGetsIt() {
        var observer = SilentTrackObserver()
        _ = observer.observe(ages(energy: 0.5))
        for _ in 0 ..< 2 * SilentTrackObserver.silentSinceFirstBufferTicks {
            XCTAssertNotEqual(observer.observe(ages(energy: 600)), .silentSinceFirstBuffer)
        }
    }

    func testBuffersStoppingIsNotAZeroRun() {
        // A tap that stopped delivering is not a tap delivering zeroes. The
        // capture layer reports that one as noBuffers, and a rebuild triggered
        // off this observer would be answering the wrong question.
        var observer = SilentTrackObserver()
        _ = observer.observe(ages(energy: 0.5))
        XCTAssertNil(observer.observe(ages(energy: 30.0, buffer: 30.0)))
        XCTAssertNil(observer.observe(ages(energy: 40.0, buffer: nil)))
        XCTAssertEqual(observer.zeroRuns, 0)
    }

    func testARunEndedByBuffersStoppingDoesNotReportAnExit() {
        var observer = SilentTrackObserver()
        _ = observer.observe(ages(energy: 11.0))
        XCTAssertNil(
            observer.observe(ages(energy: 35.0, buffer: 25.0)),
            "the transport died; that is not signal coming back",
        )
        XCTAssertTrue(observer.inZeroRun, "and the run is still open")
    }

    // MARK: - Bounds

    func testTheEdgeLogIsCappedButTheCountersKeepGoing() {
        var observer = SilentTrackObserver()
        var events = 0
        // Ten full cycles is twenty edges, exactly the cap.
        for _ in 0 ..< 10 {
            if observer.observe(ages(energy: 11.0)) != nil { events += 1 }
            if observer.observe(ages(energy: 0.02)) != nil { events += 1 }
        }
        XCTAssertEqual(events, SilentTrackObserver.maxEdgesPerRecording)

        // An eleventh cycle is silent in the log ...
        XCTAssertNil(observer.observe(ages(energy: 11.0)))
        XCTAssertNil(observer.observe(ages(energy: 0.02)))
        // ... but the stop summary still counts it, which is the point of the
        // cap: bound the log, not the evidence.
        XCTAssertEqual(observer.zeroRuns, 11)
    }
}
