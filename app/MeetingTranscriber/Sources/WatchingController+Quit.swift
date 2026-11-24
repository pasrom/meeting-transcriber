// The watching side of a quit (see `TerminationFlush`): stop watching and
// hand whatever is recording to the pipeline before the snapshot is flushed.
//
// Stop Watching in the middle of a meeting sets the loop idle and lets go of
// it while it goes on mixing and enqueueing what it recorded, off the main
// actor. Two things reach such a loop after that: `unfinishedRecordingWork`,
// shared by every loop built here, which a quit waits for; and `builtLoops`,
// which holds every loop `watchLoop` has held weakly (a mixing loop's task
// keeps it alive until it is done), so a queue replacement and a quit's
// `finishingForQuit` reach it too.
extension WatchingController {
    /// Whether a quit has to wait for watching or recording to finish.
    var hasWorkBeforeQuit: Bool {
        manualStartTask != nil || watchLoop?.hasWorkBeforeQuit == true || !unfinishedRecordingWork.isEmpty
    }

    /// Wait for loops Stop Watching let go of to finish their mix before a
    /// watch start rebuilds the queue: the rebuild runs the staging recovery,
    /// which could take a stem still being mixed for a crashed recording.
    /// False when the start has to give up meanwhile.
    func waitForStoppedLoopsBeforeRebuild() async -> Bool {
        guard !unfinishedRecordingWork.isEmpty else { return true }
        await unfinishedRecordingWork.waitForAll()
        return !isManualRecording && !isQuitting
    }

    /// Stop watching for a quit. Returns once an in-flight recording, auto or
    /// manual, has been stopped and enqueued, including one whose loop Stop
    /// Watching let go of. A manual start still in flight is waited for
    /// first and starts nothing: parked on the microphone prompt it gives up
    /// on `isQuitting` once the prompt is answered (until then the quit's
    /// recording budget is what ends the wait), and past the prompt, waiting
    /// for its recorder, it gives up on the loop's `finishingForQuit`. A
    /// watch start parked on the prompt gives up the same way and is not
    /// waited for: it has recorded nothing.
    func finishForQuit() async {
        isQuitting = true
        // Every loop, also one still mixing: a stop that recorded nothing is
        // no error to report while quitting.
        for loop in builtLoops.allObjects {
            loop.finishingForQuit = true
        }
        _ = await manualStartTask?.value
        await watchLoop?.finishForQuit()
        watchLoop = nil
        await unfinishedRecordingWork.waitForAll()
    }
}
