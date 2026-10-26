import Foundation
import os.log

private let logger = Logger(subsystem: "com.meetingtranscriber.audiotap", category: "MicCapture")

/// The first start under a deadline (issue #778).
///
/// The call that brings up an engine can loop inside AVFAudio and never return
/// (issue #588). Restarts were bounded against that from the start; the first
/// start was not, and ran on the main queue, so the same wedge froze the whole
/// app until the user quit it. It now runs the way a restart does: on
/// `restartQueue`, under a generation from the arbiter, and the main queue
/// waits for it no longer than `RestartArbiter.attemptTimeout` plus
/// `firstStartReportGrace`.
///
/// `start()` stays synchronous and throwing, so `AudioCaptureSession` and the
/// microphone-first start order (issue #693) keep their shape: the main queue
/// waits for the answer, for the deadline and at most a short grace after it
/// (see `firstStartReportGrace`). That wait is a bound on a
/// block that used to have none, not a new one.
///
/// The deadline is a timed wait rather than a timer through `scheduleOnMain`,
/// which is what restarts use: a timer posted to the main queue cannot fire
/// while the main queue is the thread doing the waiting. `awaitFirstStart` is
/// the seam instead.
extension MicCaptureHandler {
    /// How long the main thread waits for the rest of an attempt's block when
    /// the deadline and the attempt's report cross. The rest does not block,
    /// so this is a grace, not a second deadline: the main thread's whole
    /// wait is at most `RestartArbiter.attemptTimeout` plus this.
    static let firstStartReportGrace: TimeInterval = 0.5

    /// The engine built at init, handed to the restart queue. Unchecked
    /// because the session is not `Sendable`; while the attempt runs nothing
    /// on the main queue reads or replaces it, since the main queue is
    /// waiting, and after a give-up only the attempt itself touches it again.
    private struct FirstEngine: @unchecked Sendable {
        let session: any MicEngineSessionProviding
    }

    /// Brings up the first engine off the main queue and waits for it for at
    /// most `RestartArbiter.attemptTimeout` plus `firstStartReportGrace`. Throws the start's own error, or
    /// `MicCaptureError.firstStartTimedOut` when it did not return in time.
    ///
    /// The outcome is read only once the attempt's block has ended, which the
    /// group says: the block leaves it on its way out, whatever it did. So
    /// nothing depends on the order in which the block stores the outcome and
    /// reports to the arbiter, and a wait that gives up in the instant the
    /// attempt reports back waits for the rest of the block, which does not
    /// block, instead of reading an outcome that may not be stored yet.
    func bringUpFirstEngine(deviceUID: String?, generation: Int) throws {
        let engine = FirstEngine(session: session)
        let outcome = OSAllocatedUnfairLock<Result<Double, any Error>?>(initialState: nil)
        let done = DispatchGroup()
        done.enter()

        restartQueue.async { [self] in
            defer { done.leave() }
            var createdOutputFile = false
            let result = Result {
                try startEngine(deviceUID: deviceUID, on: engine.session, generation: generation) {
                    createdOutputFile = true
                }
            }
            let succeeded = if case .success = result { true } else { false }
            let action = arbiter.withLock { state in
                state.handle(.attemptReturned(generation: generation, succeeded: succeeded))
            }
            startSeams.afterFirstStartReport()
            outcome.withLock { $0 = result }
            if action == .rejectStale {
                // Given up while it was out. Nothing reads this engine any
                // more, so it releases what it brought up itself.
                logger.info("Mic: discarding a first start that returned after its deadline")
                engine.session.teardown()
                // If it created the recording's file, it may have done so after
                // the deadline, when the cleanup of the failed start had
                // already looked for it: a header-only file nothing reads and
                // nothing would collect, so it goes. A file it did not create
                // was there before the start and is not this attempt's to
                // remove. (`outputURL` is internal rather than private for this.)
                if createdOutputFile {
                    outputFile = nil
                    try? FileManager.default.removeItem(at: outputURL)
                }
            }
        }

        if !awaitFirstStart(done, RestartArbiter.attemptTimeout) {
            guard arbiter.withLock({ $0.handle(.attemptTimedOut(generation: generation)) }) != .giveUp else {
                // Nothing here touches the engine: the call it is in may hold
                // its mutex. The thread stays in it for as long as the call
                // takes, which may be until the app quits.
                logger.error(
                    "Mic: the first start did not return within \(RestartArbiter.attemptTimeout, privacy: .public)s, continuing without the microphone",
                )
                throw MicCaptureError.firstStartTimedOut
            }
            // It reported back in the instant the wait gave up. The rest of its
            // block does not block; bounded anyway, so a defect there cannot
            // turn into the freeze this exists to prevent. The bound has a
            // price: should the rest of the block take longer than the grace,
            // which takes the restart queue's thread being held off for that
            // long, a start that came up is reported as timed out (and one
            // that failed as timed out rather than with its own error). Its
            // engine is not lost: the arbiter is committing, and the stop that
            // follows the throw tears it down.
            guard done.wait(timeout: .now() + Self.firstStartReportGrace) == .success else {
                throw MicCaptureError.firstStartTimedOut
            }
        }

        let result = outcome.withLock { $0 } ?? .failure(MicCaptureError.firstStartTimedOut)
        _ = try result.get()
        _ = arbiter.withLock { $0.handle(.commitReady(generation: generation)) }
    }
}

/// Test seams on the first start, no-ops in production. A test parks the
/// attempt at one of these points to land the deadline exactly there; each is
/// set before the capture starts, like `TimelineBridgeGate.beforeChunk`.
final class MicStartSeams: @unchecked Sendable {
    /// On the restart queue, after the attempt was allowed to create the
    /// output file and before it does.
    var beforeOutputFile: @Sendable () -> Void = {}
    /// On the restart queue, after the first start reported back to the
    /// arbiter and before its outcome is stored.
    var afterFirstStartReport: @Sendable () -> Void = {}
}

/// The first start's deadline as user-facing copy may name it, which the app
/// cannot read from the internal `RestartArbiter`.
public enum MicStartLimits {
    /// Seconds the main thread waits for the microphone's first start.
    public static let firstStartDeadlineSeconds = Int(RestartArbiter.attemptTimeout)
}
