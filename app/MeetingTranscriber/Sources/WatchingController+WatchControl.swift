import Foundation

/// The `/v1/watch` control surface: meeting watching as an idempotent resource a
/// remote caller can drive.
///
/// Split out alongside its `+RecordControl` sibling, so the two automation-API
/// surfaces sit next to each other rather than inside the lifecycle class both
/// of them drive. `joinStart` is internal rather than private for that split.
@MainActor
extension WatchingController {
    /// Idempotent start. Awaits the in-flight async start — mic gate, engine
    /// sync, queue rebuild, loop construction — so a caller that reports state
    /// back observes the settled result instead of a snapshot taken mid-launch.
    /// `toggleWatching` alone cannot offer that: it returns the moment the task
    /// is spawned, and `startTask` is private.
    ///
    /// Starts as not user-initiated. Nobody is at the machine when this arrives
    /// — that is the whole point of the endpoint — so the optional Accessibility
    /// prompt must not be raised, exactly as for auto-watch.
    @discardableResult
    func startWatching() async -> WatchControlOutcome {
        if isManualRecording { return .blocked }
        if isWatching { return .unchanged }
        toggleWatching(userInitiated: false)
        // `toggleWatching` assigns `startTask` synchronously, so this always
        // joins the task it just created — or, if another caller already had a
        // start in flight, the one whose existence made our call a no-op.
        guard await joinStart() else { return .failed }
        // Re-check: a manual start can register while the auto start is parked,
        // which makes that start bail and leaves `watchLoop` nil. The join
        // settled and the dialog was answered, so this is the conflict 409
        // describes, not the "did not settle" 503.
        if isManualRecording { return .blocked }
        return isWatching ? .changed : .failed
    }

    /// Idempotent stop. Awaits a pending start first: otherwise a stop issued
    /// during the mic-access window lands before the loop exists, reports
    /// "already stopped", and is then overwritten by the start completing.
    ///
    /// A manual recording is reported as `.unchanged` rather than `.blocked`:
    /// `isWatching` is false by definition while one owns the loop, so the
    /// requested end state already holds and there is nothing to refuse. That
    /// is the asymmetry with `startWatching`, where `.blocked` is right because
    /// starting would clobber the recording.
    @discardableResult
    func stopWatching() async -> WatchControlOutcome {
        guard await joinStart() else { return .failed }
        guard isWatching else { return .unchanged }
        toggleWatching()
        return isWatching ? .failed : .changed
    }

    /// Apply a watch action, resolving `.toggle` against settled state.
    ///
    /// The leading await matters for `.toggle`: deciding against a mid-launch
    /// snapshot would read "not watching" for a loop that is seconds from
    /// running, and start a second one. Settling first means a toggle racing a
    /// start converges to on — the caller asked for a flip and gets a definite
    /// answer, rather than a coin toss on where the mic prompt happened to be.
    @discardableResult
    func applyWatchAction(_ action: WatchAction) async -> WatchControlOutcome {
        guard await joinStart() else { return .failed }
        switch action {
        case .start: return await startWatching()
        case .stop: return await stopWatching()
        case .toggle: return isWatching ? await stopWatching() : await startWatching()
        }
    }
}
