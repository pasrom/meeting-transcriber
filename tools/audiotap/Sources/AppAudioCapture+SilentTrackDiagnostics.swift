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
/// `SilentTrackObserver.maxEdgesPerRecording` edges. The 5 s cadence line stays
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
    /// Three call sites drive this, and the reasoning lives here rather than at
    /// any of them.
    ///
    /// **At start**, right after `AudioDeviceStart`: a baseline for everything
    /// below, because a tap whose processes were already not running output is a
    /// different story from one whose processes stopped later. Asynchronous, so
    /// a HAL read that hangs cannot hold up the start path (issue #588).
    ///
    /// **On a zero-run edge**, from the 5 s tick.
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
        guard case let .read(states) = outcome else {
            // Not swallowed: a skip means an earlier read has not come back, and
            // if that one is wedged every later probe is skipped too. Silence
            // here would look identical to a probe nobody asked for.
            logger.info(
                "App audio process state (\(reason, privacy: .public)): skipped, a read is still outstanding",
            )
            return
        }
        guard !states.isEmpty else {
            logger.info("App audio process state (\(reason, privacy: .public)): no tapped processes")
            return
        }
        for state in states {
            let exe = getExecutableName(pid: state.process.pid)
            logger.info(
                "App audio process state (\(reason, privacy: .public)): exe=\(exe, privacy: .public) \(state.summary, privacy: .public)",
            )
        }
    }

    /// Feed one 5 s tick into the observer and log the edges. Runs on the write
    /// queue; every HAL read it triggers runs on the diagnostics queue.
    func observeSilentTrack(processes: [TappedProcess]) {
        guard let event = silentTrackDiagnostics.observe(currentSignalAges) else { return }
        switch event {
        case let .enteredZeroRun(afterSignalSeconds):
            logger.warning(
                "App audio: track has been at exact zeros for \(Self.seconds(afterSignalSeconds), privacy: .public) s while buffers keep arriving",
            )
            // The one moment worth asking the tapped processes what they are
            // doing: whether their output is still running, and whether it went
            // to a device this tap does not follow.
            silentTrackDiagnostics.probeAsync(processes, reason: "zero run started")

        case let .exitedZeroRun(durationSeconds):
            logger.info(
                "App audio: signal returned after \(Self.seconds(durationSeconds), privacy: .public) s of exact zeros",
            )
        }
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
        logger.info(
            "App audio at stop: lastBufferAge=\(lastBuffer, privacy: .public) lastEnergyAge=\(lastEnergy, privacy: .public) zeroRuns=\(counters.zeroRuns, privacy: .public) longestZeroRun=\(Self.seconds(counters.longestZeroRun), privacy: .public)",
        )
        silentTrackDiagnostics.probeAsync(silentTrackDiagnostics.lastInstalledProcesses, reason: "stop")
    }

    /// One decimal place: these are durations in seconds, and the full Double
    /// makes the line harder to read without saying anything more.
    private static func seconds(_ value: TimeInterval) -> String {
        String(format: "%.1f", value)
    }
}
