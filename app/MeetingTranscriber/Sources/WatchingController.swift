import Foundation
import Observation

// MARK: - WatchingController

/// Owns the watching / recording lifecycle: the active `WatchLoop`, the
/// auto-detect toggle, manual recording start/stop, the per-recording recorder
/// factory (which installs live-transcription sinks), and the state-change
/// handler that drives channel-health monitoring + error notifications.
///
/// Extracted from `AppState` as a concern-specific controller (see the AppState
/// god-class split). Unlike the earlier leaf controllers, watching is a hub: it
/// reaches across the already-extracted siblings — `pipeline` (to rebuild/ensure
/// the queue and pass it to the loop), `channelHealth` (start/stop on state
/// transitions), `permissions` (seed the loop's permission checker), and
/// `liveTranscription` (attach live sinks to each recorder). It holds those
/// siblings as direct references (not an `AppState` back-reference) since they
/// are all constructed before this controller in `AppState.init`.
///
/// Testability seams: `ensureMicAccess` + `makeDetector` are injectable (default
/// to the production `Permissions.ensureMicrophoneAccess` / `PowerAssertionDetector`)
/// so `toggleWatching` can be exercised without real TCC or IOKit. `syncEngines`
/// is wired post-init via `activate(syncEngines:)`: it bridges to
/// `EngineController.syncEngineSettings()` (held by `AppState`, not injected
/// here as a sibling) and the closure must capture `self` after stored-property
/// init — the same post-init wiring idiom the other controllers use.
@Observable
@MainActor
final class WatchingController {
    var watchLoop: WatchLoop?

    /// Non-nil while `toggleWatching`'s async start is in flight — it awaits mic
    /// access before `watchLoop` is assigned, so without this a second toggle in
    /// that window would launch a duplicate start. Cleared when the start task
    /// finishes.
    private var startTask: Task<Void, Never>?

    /// See `defaultStartJoinTimeout`.
    private let startJoinTimeout: Duration

    /// Set while `startManualRecording` is in flight, i.e. from the call until
    /// `watchLoop` holds the manual loop. `startTask`'s counterpart for the
    /// manual path, so `isManualRecording` covers the window before the loop
    /// exists.
    var manualStartTask: Task<ManualRecordingStartResult, Never>?

    let settings: AppSettings
    private let notifier: any AppNotifying
    private let pipeline: PipelineController
    private let channelHealth: ChannelHealthController
    private let permissions: PermissionsController
    private let liveTranscription: LiveTranscriptionCoordinator

    /// Microphone-access gate. Injectable so tests skip the real TCC prompt; the
    /// return value is intentionally ignored (the loop is created regardless, and
    /// surfaces a permission problem through its own `permissionChecker`).
    private let ensureMicAccess: () async -> Bool

    /// Screen-Recording request, fired at watch start. Injectable so tests skip
    /// the real TCC prompt.
    ///
    /// Asking is what registers the app in the Screen Recording list at all —
    /// preflighting never does — and until it is listed there is nothing for
    /// the user to switch on. It sits here, next to the microphone gate, rather
    /// than in the health check: that runs on every activation, so the request
    /// would keep arriving while the user is trying to work, and a checker
    /// causing a system prompt is a side effect nothing can inject around.
    ///
    /// The result is ignored, like the microphone gate: the permission only
    /// improves the detected meeting's title (`PowerAssertionDetector` falls
    /// back to a placeholder), so watching proceeds either way and the health
    /// check reports the state.
    private let requestScreenRecording: () -> Void

    /// Accessibility request, fired at watch start. Injectable so tests skip
    /// the real TCC prompt.
    ///
    /// `PermissionHealthCheck` already reports a missing Accessibility grant as
    /// a problem — red menu-bar badge plus a notification — because
    /// `ParticipantReader` needs it to read the Teams roster via
    /// `AXUIElementCreateApplication`. Without this call nothing ever showed the
    /// prompt, so the app diagnosed the problem but never offered the fix and
    /// the user had to find the Accessibility pane unaided.
    ///
    /// It belongs at watch start for the same reason the Screen-Recording
    /// request does: the health check runs on every activation, so prompting
    /// there would interrupt a user who is trying to work.
    ///
    /// Narrower than its two siblings on three axes, because full computer
    /// control is the most invasive grant on macOS and this one only enriches a
    /// recording. It fires only from a user-initiated toggle, since auto-watch
    /// otherwise raises a system alert three seconds after every launch with no
    /// click of any kind; only when `watchTeams` is on, since the roster read is
    /// the grant's sole consumer and is itself Teams-gated; and the production
    /// default is compiled out of the sandboxed build, which cannot use the API
    /// against another process at all.
    ///
    /// The result is ignored, like the other two gates. Watching, capture and
    /// transcription all work without the grant, so a refusal must not block the
    /// start.
    private let requestAccessibility: () -> Void

    /// Meeting detector factory for the auto-detect path. Injectable so tests can
    /// supply a deterministic detector instead of the IOKit-backed
    /// `PowerAssertionDetector`.
    private let makeDetector: () -> any MeetingDetecting

    /// Recorder factory, the `makeDetector` seam's counterpart for capture.
    ///
    /// Injectable so a test can assert that a start succeeded, or make one fail
    /// on demand, without opening the machine's real input device.
    /// `DualSourceRecorder` writes into `AppPaths.recordingsDir`, the production
    /// staging directory that orphan recovery scans, which is not somewhere a
    /// unit test may leave files. (It does start on the hosted CI runners, so
    /// this is about where the bytes land, not about whether capture works.)
    private let makeRecorder: @MainActor () -> any RecordingProvider

    /// Engine-sync hook, wired by `activate`. Bridges to
    /// `EngineController.syncEngineSettings()`; nil until `activate` runs, in
    /// which case the up-front sync is skipped (EngineController's own reactive
    /// observer still keeps the engines in line).
    private var syncEngines: (() -> Void)?

    init(
        settings: AppSettings,
        notifier: any AppNotifying,
        pipeline: PipelineController,
        channelHealth: ChannelHealthController,
        permissions: PermissionsController,
        liveTranscription: LiveTranscriptionCoordinator,
        ensureMicAccess: @escaping () async -> Bool = { await Permissions.ensureMicrophoneAccess() },
        requestScreenRecording: @escaping () -> Void = { Permissions.ensureScreenRecordingAccess() },
        requestAccessibility: @escaping () -> Void = {
            #if !APPSTORE
                Permissions.ensureAccessibilityAccess()
            #endif
        },
        startJoinTimeout: Duration = WatchingController.defaultStartJoinTimeout,
        makeDetector: (() -> any MeetingDetecting)? = nil,
        makeRecorder: @escaping @MainActor () -> any RecordingProvider = { DualSourceRecorder() },
    ) {
        self.settings = settings
        self.notifier = notifier
        self.pipeline = pipeline
        self.channelHealth = channelHealth
        self.permissions = permissions
        self.liveTranscription = liveTranscription
        self.ensureMicAccess = ensureMicAccess
        self.requestScreenRecording = requestScreenRecording
        self.requestAccessibility = requestAccessibility
        self.startJoinTimeout = startJoinTimeout
        self.makeRecorder = makeRecorder
        // Tests inject a deterministic detector; production defaults to one
        // filtered by the "Apps to Watch" toggles, re-read at each watch start.
        self.makeDetector = makeDetector ?? { [settings] in
            Self.defaultDetector(settings: settings)
        }
    }

    /// Wire the engine-sync hook. Called once from `AppState.init` after its
    /// stored-property init, where the `[weak self]` AppState closure is valid.
    func activate(syncEngines: @escaping () -> Void) {
        self.syncEngines = syncEngines
    }

    // MARK: - Derived

    var isWatching: Bool {
        watchLoop?.isActive == true && watchLoop?.isManualRecording == false
    }

    /// Whether a recording is currently in progress (the watch loop is in its
    /// `.recording` state).
    var isRecording: Bool {
        watchLoop?.state == .recording
    }

    /// Whether a manual (app-picker) recording owns the loop, or is on its way
    /// to owning it. Exposed because `toggleWatching` silently refuses in that
    /// state, and a silent refusal is invisible to a remote caller — the
    /// automation API turns this into a 409.
    ///
    /// The in-flight half matters: `startManualRecording` assigns `watchLoop`
    /// only after awaiting the mic gate, so reading the loop alone reports
    /// "no manual recording" for the whole of that window, and a remote start
    /// landing in it would build an auto loop that the manual task then
    /// overwrites without stopping.
    var isManualRecording: Bool {
        manualStartTask != nil || watchLoop?.isManualRecording == true
    }

    // MARK: - Start / Stop

    /// - Parameter userInitiated: True for a deliberate Start/Stop press, which
    ///   is the one moment where asking for an optional permission is warranted.
    ///   The auto-watch path passes false so an unattended launch raises no
    ///   system alert — including on the e2e runners, which force auto-watch on
    ///   and where a stray dialog can swallow the keystroke a lane sends.
    func toggleWatching(userInitiated: Bool = true) {
        if let loop = watchLoop, loop.isActive {
            // Refuse only for a *manual* loop. Stopping a live auto loop is safe
            // even while a manual start is registered, and the order matters:
            // between registration and the manual task stopping that loop
            // itself, a blanket refusal would turn a stop into an instant
            // `.failed` — a 503 the docs describe as "did not settle within 20
            // seconds" — and silently no-op the menu-bar toggle.
            guard !loop.isManualRecording else { return }
            loop.stop()
            watchLoop = nil
        } else {
            guard !isManualRecording else { return }
            // The start is async — mic access is awaited before `watchLoop` is
            // assigned — so a second toggle in that window would otherwise launch
            // a duplicate WatchLoop and rebuild the queue twice. Ignore it while
            // a start is already in flight.
            guard startTask == nil else { return }
            startTask = Task { @MainActor in
                defer { startTask = nil }
                await requestStartPermissions(userInitiated: userInitiated)

                // A manual start can register while this task is parked on the
                // permission gate, and nothing below re-checks. Whichever side
                // assigned `watchLoop` last would win and orphan the other loop
                // — still running, with no reference left to stop it. Bailing
                // here rather than at the assignment also keeps `pipeline.rebuild()`
                // from replacing the queue the manual loop is already wired to.
                // Nothing leaks: `loop.start()` has not run, so there is no
                // self-retaining watch task yet.
                guard !isManualRecording else { return }

                syncEngines?()
                pipeline.rebuild()

                let detector = makeDetector()

                let loop = WatchLoop(
                    detector: detector,
                    recorderFactory: makeRecorderFactory(),
                    pipelineQueue: pipeline.queue,
                    pollInterval: settings.pollInterval,
                    endGracePeriod: settings.endGrace,
                    noMic: settings.noMic,
                    micDeviceUID: settings.micDeviceUID.isEmpty ? nil : settings.micDeviceUID,
                    verboseDiagnostics: { [settings] in settings.verboseDiagnostics },
                    recordOnly: { [settings] in settings.recordOnly },
                    recordOnlyDestination: { [settings] in
                        .production(parent: settings.effectiveOutputDir)
                    },
                    notifier: notifier,
                    denyListStore: ConsentDenyListStore(settings: settings),
                )

                attachStateChangeHandler(to: loop, notifyOnRecording: true)

                if let health = permissions.health {
                    loop.permissionChecker = { health }
                }

                watchLoop = loop
                loop.start()
            }
        }
    }

    /// The permissions a watch start asks for, in the order the user meets
    /// them. Only the mic gate is awaited, because capture cannot begin without
    /// it; the other two register the app in their System Settings pane and are
    /// reported by `PermissionHealthCheck` afterwards, so a refusal delays
    /// nothing here.
    ///
    /// - Parameter userInitiated: see `toggleWatching`.
    private func requestStartPermissions(userInitiated: Bool) async {
        _ = await ensureMicAccess()
        requestScreenRecording()
        if userInitiated, settings.watchTeams {
            requestAccessibility()
        }
    }

    /// Whether a manual start may take over the loop it found, given what that
    /// loop is doing. False while it is recording: taking it over stops it, and
    /// a recording in progress is not something a later start may end.
    ///
    /// A pure function over the phase rather than an inline comparison, because
    /// the guard it backs only fires in a race that no test can schedule
    /// reliably — this is the layer that can be pinned.
    static func mayTakeOverLoop(in state: WatchLoop.State) -> Bool {
        state != .recording
    }

    // MARK: - Settling in-flight starts (shared by both control surfaces)

    /// How long a control call waits for an in-flight start before giving up.
    /// Generous against the ~2 s warm start, short enough that a wedged request
    /// still answers well inside a polling controller's patience. Injectable so
    /// a test can pin the give-up path without waiting it out.
    static let defaultStartJoinTimeout: Duration = .seconds(20)

    /// Join an in-flight start, giving up after `startJoinTimeout`. True when
    /// the start settled, false on expiry.
    ///
    /// The bound is the point. On a fresh install `toggleWatching` awaits
    /// `AVCaptureDevice.requestAccess`, which does not return until the dialog
    /// is answered — and on an `LSUIElement` app that dialog can sit unnoticed
    /// behind other windows. An unbounded join would hold the HTTP handler and
    /// its connection open for as long as the prompt is up, and because every
    /// verb joins the same task, each later POST would park and leak another
    /// connection.
    ///
    /// Polls `startTask` rather than racing `await startTask?.value` in a task
    /// group. Two things rule the group out: `Task.value` ignores cancellation,
    /// so the losing child keeps waiting, and a group awaits every child before
    /// it returns — the join would outlive its own timeout. Giving up must also
    /// not cancel the start itself, which is a user action already in progress.
    ///
    func joinStart() async -> Bool {
        await join { self.startTask != nil }
    }

    /// Bounded wait for the manual start alone, for a caller that just launched
    /// one and has to answer for how it went.
    ///
    /// The task parks on the microphone TCC prompt, which on a menu-bar app can
    /// sit unanswered behind other windows for as long as nobody looks. Awaiting
    /// its value directly would hold an HTTP handler and its connection open for
    /// exactly that long — the leak `joinStart` above exists to prevent. The task
    /// clears `manualStartTask` in its own `defer`, so polling that is polling
    /// its completion, and giving up here does not cancel a start the user may
    /// still be about to answer.
    func joinManualStart() async -> Bool {
        await join { self.manualStartTask != nil }
    }

    /// Settle *both* in-flight starts, auto and manual, under one deadline.
    ///
    /// `/v1/record` waits for a quiet moment before deciding what a request
    /// means: reading the loop mid-launch reports "nothing is recording", and
    /// the start that follows would then be a second one.
    ///
    /// One predicate rather than two joins in sequence, for two reasons. The
    /// bound stays the 20 seconds the API documents instead of doubling to 40,
    /// which would put it above the client's own timeout and report a start that
    /// then succeeds as a failure. And it is the stricter question: waiting for
    /// one and then the other can watch the auto start finish, spend the second
    /// wait on the manual one, and return true while a fresh auto start is
    /// already in flight again.
    func joinStarts() async -> Bool {
        await join { self.startTask != nil || self.manualStartTask != nil }
    }

    /// Bounded wait for an in-flight start, shared by both joins. True when it
    /// settled, false on expiry or cancellation. See `joinStart` for why the
    /// bound and the polling shape are what they are.
    private func join(while inFlight: () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + startJoinTimeout
        while inFlight() {
            if Task.isCancelled { return false }
            if ContinuousClock.now >= deadline { return false }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return true
    }

    // MARK: - Manual recording

    func startManualRecording(pid: pid_t, appName: String, title: String) {
        beginManualRecording(.app(pid: pid, appName: appName, title: title))
    }

    /// Record the system microphone with no app audio, for a meeting happening
    /// in the room (issue #633). Same ownership rules as the app path.
    ///
    /// Refused outright while "No Microphone (app audio only)" is set. The menu
    /// disables the item for the same reason, but a disabled control cannot be
    /// the enforcement: every other entry point onto this path (the automation
    /// API, a future shortcut) would otherwise record the one thing that setting
    /// exists to keep off tape, with no compile error and nothing failing.
    func startMicrophoneRecording() {
        guard !settings.noMic else {
            notifier.notify(
                title: "Microphone Recording Refused",
                body: MicrophoneRecordingAvailability.blockedByNoMicSetting.disabledReason ?? "",
            )
            return
        }
        beginManualRecording(.microphone)
    }

    /// Start a manual recording, or refuse. Returns the start's task so a caller
    /// that has to answer for the outcome can await it; nil means one of the two
    /// ownership guards below refused before anything began.
    @discardableResult
    func beginManualRecording(
        _ request: ManualRecordingRequest,
    ) -> Task<ManualRecordingStartResult, Never>? {
        // `toggleWatching`'s counterpart. The correctness added here rests on
        // `manualStartTask` being accurate, and without this a second start
        // replaces the field while the first is still in flight, whose `defer`
        // then clears the second's registration and reopens the window.
        guard manualStartTask == nil else { return nil }
        // Refuse while one is already recording. Without this the assignment
        // below replaces `watchLoop` without stopping the live loop, so its
        // recording is never enqueued while its recorder keeps capturing,
        // retained by its own monitor task and reachable by nothing (#624).
        // The picker disables Start for the same reason, but it cannot be the
        // enforcement: a recording can begin between opening it and pressing.
        guard watchLoop?.isManualRecording != true else { return nil }
        let task = Task { @MainActor in
            defer { manualStartTask = nil }
            return await performManualRecording(request)
        }
        // Assigned after construction, not inline: the body is `@MainActor` and
        // so is this, so it cannot run before we return, and the field is set
        // for the whole window either way.
        manualStartTask = task
        return task
    }

    /// Body of `beginManualRecording`, split out so the task closure stays a
    /// two-liner and the work is readable on its own.
    private func performManualRecording(
        _ request: ManualRecordingRequest,
    ) async -> ManualRecordingStartResult {
        // Settle an auto start before reading `watchLoop`. Mid-flight it is
        // still nil, so the stop below would find nothing and the auto task
        // would later assign over the manual loop, orphaning a live recording
        // with no way to stop it.
        _ = await joinStart()

        // Stop auto-watch if active
        if let loop = watchLoop, loop.isActive, !loop.isManualRecording {
            // Re-checked here, and not only wherever the caller checked it: that
            // check ran before this task was scheduled, and the poll loop can
            // have entered a meeting in the meantime. Stopping the loop then
            // truncates a recording in progress, which is the loss #624 was
            // about, reachable from the app picker (its window outlives the
            // state it was opened in) and from the automation API alike.
            guard Self.mayTakeOverLoop(in: loop.state) else {
                notifier.notify(
                    title: "Recording Refused",
                    body: "A meeting is already being recorded",
                )
                return .blockedByActiveRecording
            }
            loop.stop()
            watchLoop = nil
        }

        _ = await ensureMicAccess()

        pipeline.ensureQueue()

        // Manual recording never polls the detector, so WatchLoop's default
        // (unfiltered) detector here is inert, and so is the consent gate
        // that hangs off it: no detection means no prompt, hence no deny
        // list to consult, hence the default in-memory store. If this path
        // ever gains auto-detection, route it through `makeDetector()` like
        // toggleWatching so the "Apps to Watch" filter still applies, and
        // pass `denyListStore:` so a "Never for this app" is honoured here
        // too.
        let loop = WatchLoop(
            recorderFactory: makeRecorderFactory(),
            pipelineQueue: pipeline.queue,
            pollInterval: settings.pollInterval,
            noMic: settings.noMic,
            micDeviceUID: settings.micDeviceUID.isEmpty ? nil : settings.micDeviceUID,
            verboseDiagnostics: { [settings] in settings.verboseDiagnostics },
            recordOnly: { [settings] in settings.recordOnly },
            recordOnlyDestination: { [settings] in
                .production(parent: settings.effectiveOutputDir)
            },
            notifier: notifier,
        )
        watchLoop = loop

        // Wire channel-health monitoring + error notification on state
        // transitions — same hook the auto-detect path installs, so the
        // red-tint indicator and asymmetric-silence notification work
        // for manual recordings too.
        attachStateChangeHandler(to: loop, notifyOnRecording: false)

        // Use cached health check result instead of live probe
        if let health = permissions.health {
            loop.permissionChecker = { health }
        }

        do {
            switch request {
            case let .app(pid, appName, title):
                try await loop.startManualRecording(pid: pid, appName: appName, title: title)

            case .microphone:
                try await loop.startMicrophoneRecording()
            }
            // Read the title back off the loop rather than re-deriving it here:
            // the loop stamps it into `manualRecordingInfo`, and that is the
            // same value the job and the record-only sidecar get, so the
            // notification cannot end up naming the recording something else.
            notifier.notify(
                title: "Manual Recording",
                body: "Recording: \(loop.manualRecordingInfo?.title ?? "")",
            )
            return .started
        } catch {
            notifier.notify(title: "Error", body: error.localizedDescription)
            watchLoop = nil
            // The permission arm is told apart by the error the gate raises, not
            // by re-asking the health check here: only the loop knows which
            // source it was about to record, and the whole point of that gate is
            // that the answer differs per source.
            guard let recorderError = error as? RecorderError,
                  case .permissionDenied = recorderError
            else { return .failed }
            return .permissionRefused
        }
    }

    func stopManualRecording() {
        watchLoop?.stopManualRecording()
        watchLoop = nil
    }

    // MARK: - Recorder factory

    /// Build the `recorderFactory` closure for `WatchLoop`. Returns a fresh
    /// `DualSourceRecorder` on each invocation; when live captions are eligible,
    /// the coordinator installs mic + app live sinks that pipe captured buffers to
    /// the `LiveTranscriptionController`. `async` so the coordinator can await the
    /// prior recording's stop-time flush before reusing a kept EOU session.
    private func makeRecorderFactory() -> @MainActor () async -> any RecordingProvider {
        { [weak self, makeRecorder] in
            let recorder = makeRecorder()
            // Live captions tap the concrete recorder's buffer sinks, so this is
            // the production recorder or nothing. An injected double has no
            // sinks and needs none: captions are off in every test that uses one.
            if let dualSource = recorder as? DualSourceRecorder {
                await self?.liveTranscription.attachSinks(to: dualSource)
            }
            return recorder
        }
    }

    // MARK: - State-change handler

    /// Attaches the state-change callback that drives channel-health monitoring
    /// and post-`.error` notifications. Shared between the auto-detect path
    /// (`toggleWatching`) and the manual-recording path (`startManualRecording`)
    /// so the red-tint indicator + asymmetric-silence notification fire in both.
    /// `notifyOnRecording` only fires "Meeting Detected" notifications for the
    /// auto-detect path; manual recording emits its own start notification.
    private func attachStateChangeHandler(to loop: WatchLoop, notifyOnRecording: Bool) {
        loop.onStateChange = { [weak self, weak loop, notifier] oldState, newState in
            // Leaving `.recording` (natural meeting end, manual stop, or
            // mid-recording cancel — all route through this transition) is the
            // unified stop signal for both the auto-detect and manual paths.
            // Flush the live pipeline here so the pending tail utterance is
            // committed before the next recording's prepareForNextRecording() clears state. The
            // flush runs after `recorder.stop()` (WatchLoop stops the recorder
            // before this transition fires); the buffered tail lives in the
            // streaming actors, not the recorder, so it survives the stop.
            if oldState == .recording {
                Task { @MainActor in await self?.liveTranscription.flush() }
            }
            switch newState {
            case .recording:
                if notifyOnRecording, let meeting = loop?.currentMeeting {
                    notifier.notify(
                        title: "Meeting Detected",
                        body: "Recording: \(meeting.windowTitle)",
                    )
                }
                // No source means no live recording, so there are no channels to
                // watch and starting the monitor would only assume a topology.
                if let source = self?.watchLoop?.activeRecordingSource {
                    self?.channelHealth.start(source: source) { [weak self] in
                        self?.watchLoop?.activeRecorder
                    }
                }

            case .error:
                if let err = loop?.lastError {
                    notifier.notify(title: "Error", body: err)
                }
                self?.channelHealth.stop()

            default:
                self?.channelHealth.stop()
            }
        }
    }
}
