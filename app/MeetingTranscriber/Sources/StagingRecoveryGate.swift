// One staging recovery at a time in this process, each judging file ages from
// when it was asked for.
//
// Every queue rebuild starts a staging recovery (header repair, crash re-mix,
// temp cleanup). Two that overlap on one crashed stem can end with a
// microphone-only mix over the complete one: the second finds the stem not yet
// mixed, the first mixes it and consumes the raw app temp, and the second
// rebuilds from the microphone track alone. The cleanup of one can also delete
// a raw temp the other is about to re-mix.
//
// The gate is a serial queue. A caller waits by suspending, not by parking a
// thread of the cooperative pool: the work runs on the gate's own queue. It
// covers this process only; a second running app instance shares the staging
// folder and is not covered.
//
// A recovery that waited behind another (a re-mix of a long recording takes
// minutes) still tells a crashed recording from a live one by the time of its
// request: every age guard in the work is measured from `requestedAt`, so a
// recording that began while it waited, and whose tracks then stopped
// advancing, does not become eligible merely because the wait was long.
import Foundation
import os.log

enum StagingRecoveryGate {
    private static let queue = DispatchQueue(label: "com.meetingtranscriber.staging-recovery", qos: .utility)

    /// The staging recovery production runs on each queue build: repair
    /// unfinalized headers, re-mix crashed recordings, delete the temps the
    /// re-mix could not use, in that order and through the gate. `minAge` is
    /// the age guard of all three, measured back from `requestedAt`.
    static func recover(in staging: URL, requestedAt: Date = Date(), minAge: TimeInterval = 30) async {
        await run {
            let repaired = WavHeaderRepair.repairUnfinalized(in: staging, minAge: minAge, now: requestedAt)
            if repaired > 0 { logger.info("Repaired \(repaired) unfinalized recording(s) on launch") }
            let recovered = DualSourceRecorder.recoverCrashedRecordings(in: staging, minAge: minAge, now: requestedAt)
            if recovered > 0 { logger.info("Recovered \(recovered) crashed recording(s) on launch") }
            DualSourceRecorder.cleanupTempFiles(recordingsDir: staging, minAge: minAge, now: requestedAt)
        }
    }

    /// Run `work` once every staging recovery started before it in this
    /// process has finished.
    static func run(_ work: @escaping @Sendable () -> Void) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            queue.async {
                work()
                continuation.resume()
            }
        }
    }
}

private let logger = Logger(subsystem: AppPaths.logSubsystem, category: "StagingRecovery")
