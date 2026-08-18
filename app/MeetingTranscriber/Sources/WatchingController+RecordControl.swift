import Foundation

/// The `/v1/record` control surface: microphone recording as an idempotent
/// resource a remote caller can drive, alongside the watch control in
/// `WatchingController` proper.
///
/// Its own file because that one sits at the line cap; the handful of members it
/// reaches into (`settings`, `watchLoop`, `manualStartTask`, `joinStarts`,
/// `joinManualStart`, `beginManualRecording`, `stopManualRecording`,
/// `startWatching`) are internal rather than private for exactly that.
///
/// The whole surface is about one recording shape, `RecordingSource.micOnly`.
/// Everything else the loop can be doing — an app-picker recording, an
/// auto-detected meeting — is somebody else's recording here: a start refuses
/// rather than clobbering it, and a stop leaves it alone rather than ending a
/// meeting the caller never asked about.
@MainActor
extension WatchingController {
    /// Whether a microphone-only recording is in progress.
    ///
    /// Derived from `activeRecordingSource`, the loop's own answer to "what is
    /// being captured", rather than from a flag this file would have to keep in
    /// step. It reads nil until the loop is actually recording, which is why
    /// every caller below settles the in-flight starts first.
    var isRecordingMicrophoneOnly: Bool {
        watchLoop?.activeRecordingSource == .micOnly
    }

    /// Whether something other than a microphone recording owns the loop.
    ///
    /// Both halves of that matter. It is what makes a start a 409 instead of a
    /// clobbered recording (#624), and it is what keeps a microphone recording
    /// that is *already running* out of the way of a request to start one — that
    /// is not a conflict, it is the requested end state.
    var isRecordingOtherThanMicrophone: Bool {
        guard let source = watchLoop?.activeRecordingSource else { return false }
        return source != .micOnly
    }

    /// Whether a manual start is registered but has not produced a recording
    /// yet. Deliberately not "some manual recording exists": an app recording
    /// that is already running is reported by `isRecordingOtherThanMicrophone`,
    /// and calling that pending would tell a key to wait for something that is
    /// never going to become its recording.
    var isManualStartPending: Bool {
        manualStartTask != nil
    }

    /// Apply a record action, resolving `.toggle` against settled state.
    ///
    /// The join leads, for the reason `applyWatchAction` gives: deciding against
    /// a mid-launch snapshot would read "nothing is recording" for a recording
    /// that is seconds from running, and start a second one.
    @discardableResult
    func applyRecordAction(_ action: RecordAction) async -> RecordControlOutcome {
        guard await joinStarts() else { return .failed }
        switch action {
        case .start: return await applyRecordStart()

        case .stop: return applyRecordStop()

        case .toggle:
            return isRecordingMicrophoneOnly ? applyRecordStop() : await applyRecordStart()
        }
    }

    /// Idempotent start. Awaits the start it launched — mic gate, queue, loop
    /// construction, the permission gate inside `WatchLoop` — so the caller
    /// reports the settled result rather than a snapshot taken mid-launch, and
    /// so a refusal reaches it as a refusal instead of as a silent no-op.
    private func applyRecordStart() async -> RecordControlOutcome {
        if isRecordingMicrophoneOnly { return .unchanged }
        if isRecordingOtherThanMicrophone { return .blocked }
        if settings.noMic { return .refused }
        // Read before the start, because the start is what takes the loop away.
        let wasWatching = isWatching
        // nil means an ownership guard refused between the check above and here.
        guard let start = beginManualRecording(.microphone) else { return .blocked }
        // Bound the start we just launched, not only the ones we found running.
        // Without this the endpoint has no deadline at all in the one case the
        // docs name for its 503: an unanswered microphone prompt.
        guard await joinManualStart() else { return .failed }
        switch await start.value {
        // Trust the result rather than re-reading the state: a stop that landed
        // between the task finishing and this line would turn a recording that
        // started, and was then deliberately ended, into "did not settle".
        case .started: return .changed
        case .blockedByActiveRecording: return .blocked
        case .permissionRefused: await rearmWatching(wasWatching); return .refused
        case .failed: await rearmWatching(wasWatching); return .failed
        }
    }

    /// Put meeting watching back after a start that captured nothing.
    ///
    /// A manual start stops an active auto loop before it knows whether it can
    /// record, so a refusal leaves detection off. That is survivable in the menu
    /// bar, where the icon shows it. Over the API it is not: the answer says
    /// "nothing changed, fix a setting and retry" while the machine has quietly
    /// stopped watching for meetings, and nothing re-arms it until relaunch.
    private func rearmWatching(_ wasWatching: Bool) async {
        guard wasWatching, !isWatching else { return }
        await startWatching()
    }

    /// Idempotent stop, and only of a microphone recording.
    ///
    /// Anything else running reports `.unchanged` rather than `.blocked`: no
    /// microphone recording is in progress, so the requested end state already
    /// holds and there is nothing to refuse. Same asymmetry `stopWatching`
    /// documents, and the same reason — a stop that reached across and ended
    /// somebody else's meeting would be far worse than a 200 that did nothing.
    private func applyRecordStop() -> RecordControlOutcome {
        guard isRecordingMicrophoneOnly else { return .unchanged }
        let loop = watchLoop
        let errorBeforeStop = loop?.lastError
        stopManualRecording()
        if isRecordingMicrophoneOnly { return .failed }
        // A stop whose recorder threw is not a success, however idle the loop
        // looks afterwards: `WatchLoop.stopManualRecording` skips the enqueue on
        // a throw, so there is no job, no transcript and no protocol, and this
        // controller has already dropped the loop that knows why. Answering 200
        // there tells the caller their recording is safe when it is gone.
        if let errorAfterStop = loop?.lastError, errorAfterStop != errorBeforeStop {
            return .failed
        }
        return .changed
    }
}
