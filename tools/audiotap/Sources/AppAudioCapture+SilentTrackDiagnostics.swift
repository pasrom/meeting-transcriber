import Foundation
import os.log

private let logger = Logger(subsystem: "com.meetingtranscriber.audiotap", category: "AppAudioCapture")

/// The log call sites for the silent-track instrumentation (issue #672), split
/// from `AppAudioCapture.swift` to stay under the 600-line lint cap, and kept
/// together so the wording and the privacy annotations are readable in one
/// place.
///
/// **Why these lines are not gated on verbose logging.** The library's
/// convention is that per-buffer forensics are gated and that one triage line
/// per recording is not: the existing `App audio tap: N PID(s)` line is
/// unconditional precisely so a silent-track report can be triaged without the
/// user having turned Verbose Audio Logging on beforehand, which they cannot do
/// retroactively. A run of exact zeros is that same kind of event, and it is
/// bounded: two lines per process at start and stop, plus at most
/// `SilentTrackObserver.maxEdgesPerRecording` edges, plus one reading for a
/// track that has been silent since its first buffer. The 5 s cadence line stays
/// gated, because 720 lines an hour is not a triage line.
///
/// **Privacy.** These carry pids, executable names, booleans, CoreAudio object
/// ids and status codes. Executable names are already logged unconditionally by
/// `startCapture` for the same triage reason. Bundle ids and device names are
/// gated elsewhere in this file's neighbours and stay out of here entirely, and
/// no path is interpolated anywhere, so the username-in-a-path leak does not
/// apply.
@available(macOS 14.2, *)
extension AppAudioCapture {
    /// The call sites below drive this, and the reasoning lives here rather
    /// than at any of them. The scheduled probes for a tap that never delivered
    /// a first buffer report here too, under the reasons
    /// `NoFirstBufferProbeSchedule` names (issue #693); the watchdog's own
    /// checks do not, by design (`reportToSink: false`).
    ///
    /// **At start**, right after `AudioDeviceStart`: a baseline for everything
    /// below, because a tap whose processes were already not running output is a
    /// different story from one whose processes stopped later. Asynchronous, so
    /// a HAL read that hangs cannot hold up the start path (issue #588).
    ///
    /// **On a zero-run edge**, from the 5 s tick.
    ///
    /// **Once for a track silent since its first buffer**, from the same tick
    /// (issue #671). A zero run needs signal first, so without this reading a
    /// track at zeros from the start was read only at start, before a call's
    /// audio is up, and at stop, after it ended. Where the processes render
    /// mid-call is what separates a tap that cannot hear them (issue #524) from
    /// a far end rendered into a voice-processing device.
    ///
    /// **At stop**, from `stop()` and specifically *not* from `stopCapture()`.
    /// The reading is taken from the processes the last adoption remembered, not
    /// from the live session, which `.stopAndRetry` clears before any restart
    /// attempt launches and only adoption puts back.
    /// A device-change restart calls `stopCapture()` too, so a summary there
    /// would claim "at stop" in the middle of a recording, and it would stay
    /// silent on the give-up path, whose zero-run history is the one that
    /// matters most. `stop()` covers both of its branches because the reading is
    /// taken before the arbiter decides, while the session is still there.
    /// Asynchronous, which is why the line arrives after "Audio capture stopped"
    /// and says "(stop)" so the order is not misread. Reading the process
    /// objects a moment after the tap is gone is still the state at stop: they
    /// belong to coreaudiod's model of the tapped process, not to our tap.
    ///
    /// The counters deliberately span restarts rather than resetting with each
    /// tap: the question the summary answers is whether *this recording's* app
    /// track went silent, and a restart is an event inside a recording.
    ///
    /// The sink `SilentTrackDiagnostics` reports into, on its own queue.
    /// `@Sendable` and static because it must not capture a capture instance.
    static let logSilentTrackProbe: SilentTrackDiagnostics.Sink = { reason, outcome in
        guard case let .read(snapshot) = outcome else {
            // Not swallowed: a skip means an earlier read has not come back, and
            // if that one is wedged every later probe is skipped too. Silence
            // here would look identical to a probe nobody asked for.
            logger.info(
                "App audio process state (\(reason, privacy: .public)): skipped, a read is still outstanding",
            )
            return
        }
        // Before the per-process lines and independent of them: a tap with no
        // processes still has an aggregate, and "the aggregate never started"
        // is the finding that outlives every process detail (issue #693).
        if let device = snapshot.device {
            logger.info(
                "App audio device (\(reason, privacy: .public)): \(device.summary, privacy: .public)",
            )
        }
        guard !snapshot.processes.isEmpty else {
            logger.info("App audio process state (\(reason, privacy: .public)): no tapped processes")
            return
        }
        for state in snapshot.processes {
            let exe = getExecutableName(pid: state.process.pid)
            logger.info(
                "App audio process state (\(reason, privacy: .public)): exe=\(exe, privacy: .public) \(state.summary, privacy: .public)",
            )
        }
    }

    /// Feed one 5 s tick into the observer and log the edges. Runs on the write
    /// queue; every HAL read it triggers runs on the diagnostics queue.
    func observeSilentTrack(ages: ChannelSignalAges, processes: [TappedProcess]) {
        guard let event = silentTrackDiagnostics.observe(ages) else { return }
        switch event {
        case let .enteredZeroRun(afterSignalSeconds):
            logger.warning(
                "App audio: track has been at exact zeros for \(Self.seconds(afterSignalSeconds), privacy: .public) s while buffers keep arriving",
            )
            // The one moment worth asking the tapped processes what they are
            // doing: whether their output is still running, and whether it went
            // to a device this tap does not follow.
            probeTappedProcesses(processes, reason: "zero run started")

        case let .exitedZeroRun(durationSeconds):
            logger.info(
                "App audio: signal returned after \(Self.seconds(durationSeconds), privacy: .public) s of exact zeros",
            )

        case .silentSinceFirstBuffer:
            // Info, not a warning: a first minute at zeros is also what joining
            // a call early or a muted far end looks like. The stop line's
            // `lastEnergyAge=never` is what flags a track that never recovered.
            // The age is measured from the recording's first buffer, not
            // derived from the tick count, which stretches with the IOProc.
            let age = secondsSinceFirstBuffer.map(Self.seconds) ?? "unknown"
            logger.info(
                "App audio: track has carried only exact zeros since its first buffer, \(age, privacy: .public) s ago",
            )
            probeTappedProcesses(processes, reason: "silent since the first buffer")
        }
    }

    /// Age of the recording's first app buffer. `appFirstFrameTime` is stamped
    /// on the write queue, which this runs on, and a restart never overwrites it.
    private var secondsSinceFirstBuffer: TimeInterval? {
        guard appFirstFrameTime != 0 else { return nil }
        return machTicksToSeconds(mach_absolute_time() - appFirstFrameTime)
    }

    /// The logged process-state reading, against the aggregate the last
    /// adoption installed.
    private func probeTappedProcesses(_ processes: [TappedProcess], reason: String) {
        silentTrackDiagnostics.probeAsync(
            processes,
            aggregateID: silentTrackDiagnostics.lastInstalledAggregateID,
            reason: reason,
        )
    }

    /// One line saying what the app track did over the whole recording, plus the
    /// tapped processes' final state. Called from `stop()` on the main queue.
    ///
    /// The processes come from the diagnostics object rather than the session,
    /// which is nil on every give-up and mid-restart stop. `debugTotalBytes` is
    /// deliberately not reported here: the IOProc may still be writing it on the
    /// write queue at this point, and the gated stopping line already carries it.
    func logSilentTrackSummary() {
        let counters = silentTrackDiagnostics.counters
        let ages = currentSignalAges
        let lastBuffer = ages.secondsSinceLastBuffer.map(Self.seconds) ?? "never"
        let lastEnergy = ages.secondsSinceLastEnergy.map(Self.seconds) ?? "never"
        // The watchdog's counters ride on the same line when it was on, so one
        // grep gives the whole recording; when it was off the line is exactly
        // what it was before the watchdog existed.
        let watchdog = silentTrackWatchdogSummary.map { " " + $0 } ?? ""
        logger.info(
            "App audio at stop: lastBufferAge=\(lastBuffer, privacy: .public) lastEnergyAge=\(lastEnergy, privacy: .public) zeroRuns=\(counters.zeroRuns, privacy: .public) longestZeroRun=\(Self.seconds(counters.longestZeroRun), privacy: .public)\(watchdog, privacy: .public)",
        )
        probeTappedProcesses(silentTrackDiagnostics.lastInstalledProcesses, reason: "stop")
    }

    /// One decimal place: these are durations in seconds, and the full Double
    /// makes the line harder to read without saying anything more.
    /// Internal so the watchdog's lines format durations the same way.
    static func seconds(_ value: TimeInterval) -> String {
        String(format: "%.1f", value)
    }
}
