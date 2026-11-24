// Where a recording goes once it has stopped: the pipeline queue, or the
// record-only output folder. Split out of `WatchLoop.swift` to keep that file
// under the line cap; nothing here touches the loop's private state.
import Foundation
import os.log

private let logger = Logger(subsystem: AppPaths.logSubsystem, category: "WatchLoop")

extension WatchLoop {
    /// Stop `recorder` and enqueue what it recorded, with the file work off
    /// the main actor: the mix (`stopOffMain`) and, in record-only mode, the
    /// move into the output folder (`writeRecordOnlyOffMain`). Both take
    /// seconds at the end of a long recording (the mix about 17 s an hour in a
    /// debug build), which on the main actor froze the app and, during a
    /// quit, held the budget timer that is meant to bound it. Ending the
    /// capture session is the part that stays on the main actor.
    func stopAndEnqueue(
        _ recorder: any RecordingProvider,
        title: String,
        appName: String,
        trigger: RecordingSidecar.Trigger,
        participants: [String] = [],
    ) async throws {
        let recording = try await recorder.stopOffMain()
        if recordOnly() {
            await writeRecordOnlyOffMain(
                title: title, appName: appName, recording: recording, trigger: trigger, participants: participants,
            )
        } else {
            enqueueRecording(
                title: title, appName: appName, recording: recording, trigger: trigger, participants: participants,
            )
        }
    }

    private func enqueueRecording(
        title: String,
        appName: String,
        recording: RecordingResult,
        trigger: RecordingSidecar.Trigger,
        participants: [String],
    ) {
        // Kept with the tracks for a later re-import; stage 3 moves it with them.
        RecordingSidecar.writeRecordingSidecar(
            for: recording, title: title, appName: appName, trigger: trigger, participants: participants,
        )
        let job = PipelineJob(
            meetingTitle: title,
            appName: appName,
            mixPath: recording.mixPath,
            appPath: recording.appPath,
            micPath: recording.micPath,
            micDelay: recording.micDelay,
            micMuteIntervals: recording.micMuteIntervals,
            participants: participants,
            meetingStartTime: recording.recordingStartDate,
        )
        pipelineQueue?.enqueue(job)
        logger.info("Enqueued pipeline job for: \(title, privacy: .private)")
    }
}
