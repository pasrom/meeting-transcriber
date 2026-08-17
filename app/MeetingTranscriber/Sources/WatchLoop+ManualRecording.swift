import Foundation
import os.log

private let logger = Logger(subsystem: AppPaths.logSubsystem, category: "WatchLoop")

/// The poll loop that decides when a manually started recording ends, split out
/// of `WatchLoop.swift` to keep that file under the line cap.
///
/// Only the monitor moved. The start and stop paths mutate `activeRecorder`,
/// `manualRecordingTask` and `watchTask`, all of which are private to the class
/// on purpose, and moving them here would mean widening those to internal for a
/// line count. The monitor reads nothing but injected dependencies.
extension WatchLoop {
    func monitorManualRecording(pid: pid_t?) async {
        let startTime = nowProvider()
        while !Task.isCancelled {
            // No PID means a microphone-only recording, which has no process
            // that could exit; the duration cap below is its only stop signal.
            let target: ManualRecordingTarget = pid.map { pidAliveCheck($0) ? .alive : .exited } ?? .untargeted
            let decision = ManualRecordingMonitorPolicy.step(
                target: target,
                elapsed: nowProvider().timeIntervalSince(startTime),
                maxDuration: maxDuration,
            )
            switch decision {
            case .continuePolling:
                break

            case .stopPidExited:
                logger.info("Monitored app (PID \(pid ?? 0)) exited — stopping manual recording")
                stopManualRecording()
                return

            case .stopMaxDurationExceeded:
                logger.info("Max recording duration reached — stopping manual recording")
                stopManualRecording()
                return
            }
            try? await sleepProvider(pollInterval)
        }
    }
}
