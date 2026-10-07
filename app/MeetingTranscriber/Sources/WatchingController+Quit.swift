// The watching side of a quit (see `TerminationFlush`): stop watching and
// hand whatever is recording to the pipeline before the snapshot is flushed.
extension WatchingController {
    /// Whether a quit has to wait for watching or recording to finish.
    var hasWorkBeforeQuit: Bool {
        manualStartTask != nil || watchLoop?.hasWorkBeforeQuit == true
    }

    /// Stop watching for a quit. Returns once an in-flight recording, auto or
    /// manual, has been stopped and enqueued. A manual start still in flight
    /// is waited for first and starts nothing: parked on the microphone
    /// prompt it gives up on `isQuitting` once the prompt is answered (until
    /// then the quit's recording budget is what ends the wait), and past the
    /// prompt, waiting for its recorder, it gives up on the loop's
    /// `finishingForQuit`. A watch start parked on the prompt gives up the
    /// same way and is not waited for: it has recorded nothing.
    func finishForQuit() async {
        isQuitting = true
        watchLoop?.finishingForQuit = true
        _ = await manualStartTask?.value
        await watchLoop?.finishForQuit()
        watchLoop = nil
    }
}
