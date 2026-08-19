import AppKit
import AudioTapLib

// `@preconcurrency`: AVFoundation types lack Sendable annotations —
// same gap as AudioMixer.swift; preemptively guarded.
@preconcurrency import AVFoundation
import Foundation
import os.log

private let logger = Logger(subsystem: AppPaths.logSubsystem, category: "DualSourceRecorder")

/// Result of a recording session.
struct RecordingResult {
    let mixPath: URL
    let appPath: URL?
    let micPath: URL?
    let micDelay: TimeInterval
    /// Wall-clock time recording started, captured directly in `start()`.
    /// Not derived from `systemUptime` (which doesn't advance during sleep, so
    /// a meeting spanning a sleep would skew the anchor) — this is exact.
    let recordingStartDate: Date
}

/// The format `buildRecording` should expect the app track to arrive in, passed
/// explicitly so the processing logic stays free of instance state (and
/// unit-testable). `requested*` describe the file the capture session is
/// expected to produce — 16 kHz mono since `AppAudioCapture` resamples in the
/// IOProc — so a logged mismatch flags the unexpected fallback/legacy path, not
/// routine device renegotiation. `targetRate` is the rate we resample/mix to.
struct CaptureFormat {
    let requestedChannels: Int
    let requestedRate: Int
    let targetRate: Int
}

/// Orchestrates app audio capture (via AudioTapLib) + mic recording, then mixes.
@MainActor
@Observable
class DualSourceRecorder: RecordingProvider {
    /// The session capturing right now, nil between recordings. Stored as the
    /// `AudioCapturing` role rather than the concrete `AudioCaptureSession`,
    /// which is what removes the `@available` gate from this property — the
    /// reason the storage used to be a type-erased `AnyObject` plus a cast.
    private var captureSession: (any AudioCapturing)?
    private(set) var isRecording = false
    private(set) var recordingStartDate: Date = .distantPast
    private var startTimestamp: String?

    var appLevelDBFS: Double {
        captureSession?.appLevelDBFS ?? -120
    }

    var micLevelDBFS: Double {
        captureSession?.micLevelDBFS ?? -120
    }

    var appCaptureGaveUp: Bool {
        captureSession?.appCaptureGaveUp ?? false
    }

    var micCaptureGaveUp: Bool {
        captureSession?.micCaptureGaveUp ?? false
    }

    /// Requested app-audio capture format (what the CATap aggregate device is
    /// asked for). The device may renegotiate to another rate/channel count
    /// mid-session; `AppAudioCapture` resamples every buffer to 16 kHz mono in
    /// the IOProc regardless, so the written file — and crash recovery — are
    /// always at the speech target rate, not this one.
    nonisolated static let defaultRecordRate = 48000
    nonisolated static let defaultAppChannels = 2

    private let recordRate = DualSourceRecorder.defaultRecordRate
    private let targetRate = AudioConstants.targetSampleRate
    private let appChannels = DualSourceRecorder.defaultAppChannels

    /// The staging directory every other consumer reads independently: the
    /// janitor, crash recovery, the orphan scan and `AudioPersistencePolicy`
    /// all resolve `AppPaths.recordingsDir` for themselves. Named rather than
    /// inlined as a default argument so a test can pin the two together.
    static let defaultRecordingsDir = AppPaths.recordingsDir

    /// Where this recorder stages its tracks.
    ///
    /// Injectable so a test can drive a whole recording without writing into
    /// the production staging directory. **Only a test may inject one:** the
    /// consumers above are not part of this seam, so a production recorder
    /// staging anywhere else would write markers and tracks that no recovery,
    /// no janitor and no orphan scan ever looks at, and whose finished mix
    /// `AudioPersistencePolicy` would misread as a user-picked import.
    private let recordingsDir: URL

    /// Builds the capture session each recording runs on. Same injection
    /// `WatchingController` already makes one level up with `makeRecorder`.
    private let makeCaptureSession: CaptureSessionFactory

    /// `makeCaptureSession`'s default wraps the factory in a closure rather
    /// than naming it: a bare reference to a static declared in another file
    /// compiles here and then fails to link.
    init(
        recordingsDir: URL = DualSourceRecorder.defaultRecordingsDir,
        makeCaptureSession: @escaping CaptureSessionFactory = { try LiveCaptureSession.make($0) },
    ) {
        self.recordingsDir = recordingsDir
        self.makeCaptureSession = makeCaptureSession
    }

    /// Remove leftover raw app temp files (current or legacy suffix) a previous
    /// crash left behind. Run AFTER `recoverCrashedRecordings` (which consumes
    /// the recoverable ones via `buildRecording`) so a rescuable recording isn't
    /// deleted before it's re-mixed — only genuinely unusable temps (e.g.
    /// 0-byte) remain to delete.
    ///
    /// `minAge` skips a temp still being written by an in-progress recording
    /// (recent mtime). This runs in the launch queue-build Task, which a
    /// watch-start fires immediately before the loop may begin a new recording;
    /// without the guard an unconditional delete could race a live temp and
    /// silently drop its app track. Same guard as `recoverCrashedRecordings`.
    nonisolated static func cleanupTempFiles(
        recordingsDir: URL = AppPaths.recordingsDir,
        minAge: TimeInterval = 30,
        reapMarkersWrittenBefore: Date? = nil,
    ) {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: recordingsDir,
            includingPropertiesForKeys: nil,
        ) else { return }
        let cutoff = Date().addingTimeInterval(-minAge)
        let markerCutoff = reapMarkersWrittenBefore ?? launchedAt

        for file in entries where RecordingFileSuffix.stripAppRaw(from: file.lastPathComponent) != nil {
            if let mtime = (try? fm.attributesOfItem(atPath: file.path)[.modificationDate]) as? Date,
               mtime > cutoff { continue }
            try? fm.removeItem(at: file)
            logger.info("Removed orphaned temp file: \(file.lastPathComponent)")
        }

        // Markers whose recording can never be rescued. A start that threw
        // before capture opened leaves one with no tracks at all; a track that
        // never received a buffer is a bare header. Either way recovery fails
        // on that stem at every launch and every watch-start, warning each
        // time, and nothing else deletes a marker — so without this pass they
        // are permanent.
        //
        // The guard is "written before this process existed", NOT the `minAge`
        // window pass 1 uses, because the two files age differently: a raw temp
        // is touched on every buffer, so a live one is always fresh, while a
        // marker is written once at start and never again. Its age is the
        // recording's length, so any window at all eventually expires under a
        // recording that is still running — and a mic wedged mid-capture (the
        // issue #588 shape) delivers no buffers, leaving a bare-header track
        // that reads as nothing worth keeping. Reaping there would strand the
        // recording for good: once the marker is gone a later crash leaves a
        // lone `_mic.wav`, which is invisible to crash recovery AND to the
        // orphan scan, which only takes paired groups. This pass also runs on
        // every watch-start, behind a re-mix that can take minutes, so "the
        // recording only just began" is not a bound that holds.
        for file in entries {
            guard let stem = RecordingFileSuffix.stripInProgress(from: file.lastPathComponent),
                  let written = (try? fm.attributesOfItem(atPath: file.path)[.modificationDate]) as? Date,
                  written < markerCutoff,
                  !isStillRescuable(stem: stem, in: recordingsDir) else { continue }
            try? fm.removeItem(at: file)
            logger.info("Removed marker for a recording that captured nothing: \(file.lastPathComponent)")
        }
    }

    /// When this process started, as the kernel records it. Anchors the marker
    /// reaping above: a marker this process wrote is necessarily younger, so
    /// its own live recording can never be reaped, however long it runs. A
    /// lazily-initialised `Date()` would not do — nothing guarantees it is
    /// touched before the first `start()`. Unreadable resolves to the distant
    /// past, which reaps nothing at all: leaving a stale marker costs a warning
    /// per launch, reaping a live one costs the recording.
    nonisolated private static let launchedAt: Date = {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0 else { return .distantPast }
        let started = info.kp_proc.p_starttime
        return Date(timeIntervalSince1970: Double(started.tv_sec) + Double(started.tv_usec) / 1_000_000)
    }()

    /// Size of a track that never received a buffer. Measured, not assumed:
    /// `AVAudioFile` pads its header with a JUNK chunk to a 4 KB boundary, so
    /// a mic file this app opened and closed empty is exactly this large, not
    /// the canonical 44 bytes a hand-built WAV header would be. Anything
    /// carrying audio is larger; the blind spot is a foreign 44-byte-header
    /// file holding under 4 KB of PCM, a tenth of a second nobody would want
    /// rescued.
    nonisolated private static let emptyTrackBytes = 4096

    /// Whether a later recovery pass could still rescue this stem: no mix yet,
    /// and either a raw app temp or a mic track with PCM past its header. A
    /// stem that already has a mix is finished whatever its marker says, and
    /// leaving that marker would turn into a false crash the moment the
    /// finished job moves the mix into the output folder.
    ///
    /// Size is the test, not readability: an unfinalized header reads as zero
    /// frames while its PCM is intact, so probing readability here would reap
    /// the marker of a recording that is entirely rescuable. The cost of the
    /// cruder test is that a large unreadable track keeps its marker and warns
    /// once per launch, which is the direction to err in.
    ///
    /// The rejected empty track is left on disk. It is not user-visible (this
    /// is the app's staging directory), so it is 4 KB of litter rather than
    /// something to explain, and deleting audio files here is a far worse
    /// failure mode than keeping them.
    nonisolated private static func isStillRescuable(stem: String, in dir: URL) -> Bool {
        let fm = FileManager.default
        let mix = dir.appendingPathComponent(stem + RecordingFileSuffix.mix)
        guard !fm.fileExists(atPath: mix.path) else { return false }
        if crashedTemp(stem: stem, in: dir) != nil { return true }
        let mic = dir.appendingPathComponent(stem + RecordingFileSuffix.mic)
        let size = (try? fm.attributesOfItem(atPath: mic.path)[.size] as? Int) ?? 0
        return size > emptyTrackBytes
    }

    // MARK: - Crash recovery (#379 durability, part 3)

    /// Stems of recordings whose writer was killed mid-capture: a leftover raw
    /// app temp (current or legacy suffix) with no matching `_mix.wav`. In the
    /// normal flow `buildRecording` deletes the `.tmp` once the mix exists, so a
    /// surviving `.tmp` means `stop()` never ran. Pure — operates on filenames
    /// only.
    nonisolated static func crashedRecordingStems(in filenames: [String]) -> [String] {
        let mixStems = Set(filenames.compactMap { name -> String? in
            name.hasSuffix(RecordingFileSuffix.mix)
                ? String(name.dropLast(RecordingFileSuffix.mix.count)) : nil
        })
        var seen = Set<String>()
        var stems: [String] = []
        for name in filenames {
            // Either signal identifies a crash, and a dual-source one leaves
            // both, so the `seen` set keeps such a stem from being reported
            // twice. Nothing else counts: see `RecordingFileSuffix.inProgress`
            // for why a lone mic track must never be read as an interruption.
            guard let stem = RecordingFileSuffix.stripAppRaw(from: name)
                ?? RecordingFileSuffix.stripInProgress(from: name) else { continue }
            guard !mixStems.contains(stem), seen.insert(stem).inserted else { continue }
            stems.append(stem)
        }
        return stems
    }

    /// When this stem's audio was last written, across whichever tracks exist,
    /// or nil when it has none (nothing to recover, and nothing to wait for).
    nonisolated private static func lastTrackWrite(stem: String, in dir: URL) -> Date? {
        let fm = FileManager.default
        let candidates = RecordingFileSuffix.appRawAny.map { stem + $0 } + [stem + RecordingFileSuffix.mic]
        return candidates
            .map { dir.appendingPathComponent($0) }
            .compactMap { (try? fm.attributesOfItem(atPath: $0.path)[.modificationDate]) as? Date }
            .max()
    }

    /// Path of the in-progress marker for one recording.
    nonisolated static func inProgressMarker(stem: String, in dir: URL) -> URL {
        dir.appendingPathComponent(stem + RecordingFileSuffix.inProgress)
    }

    /// Locate a crashed stem's surviving temp, current format first. Returns
    /// the URL and whether it is the legacy (raw device-rate stereo) format —
    /// the temp is headerless, so the suffix is the only format marker.
    nonisolated private static func crashedTemp(stem: String, in dir: URL) -> (url: URL, isLegacy: Bool)? {
        for suffix in RecordingFileSuffix.appRawAny {
            let url = dir.appendingPathComponent(stem + suffix)
            if FileManager.default.fileExists(atPath: url.path) {
                return (url, suffix == RecordingFileSuffix.legacyAppRaw)
            }
        }
        return nil
    }

    /// Re-mix one crashed recording's surviving app track (+ mic, if present)
    /// into a `_mix.wav`, reusing the normal `buildRecording` path. A current
    /// temp is already 16 kHz mono float (`AppAudioCapture` resamples in the
    /// IOProc) and is read at the target rate; a legacy temp from a pre-upgrade
    /// version holds raw device-rate stereo and gets the pre-resampler
    /// interpretation (device rate/channels + buildRecording's mic-duration
    /// rate cross-check). The mic WAV header is repaired first (a crash leaves
    /// it unfinalized). The per-track `micDelay` is unrecoverable after a
    /// crash, so the tracks are mixed from their file starts — a sub-100 ms
    /// drift vs. a clean recording, an acceptable cost to rescue audio that
    /// would otherwise be lost.
    @discardableResult
    nonisolated static func recoverCrashedRecording(stem: String, in recDir: URL) throws -> URL {
        let temp = crashedTemp(stem: stem, in: recDir)
        let micWav = recDir.appendingPathComponent(stem + RecordingFileSuffix.mic)
        let hasMic = FileManager.default.fileExists(atPath: micWav.path)
        // No app temp is the microphone-only shape, which is recoverable from
        // the mic track alone. With neither there is nothing to rescue.
        guard temp != nil || hasMic else {
            throw RecorderError.noAudioData
        }
        if hasMic { _ = try? WavHeaderRepair.repairIfNeeded(at: micWav) }

        let rate = temp?.isLegacy == true ? defaultRecordRate : AudioConstants.targetSampleRate
        let channels = temp?.isLegacy == true ? defaultAppChannels : 1
        let result = AudioCaptureResult(
            appAudioFileURL: temp?.url,
            micAudioFileURL: hasMic ? micWav : nil,
            actualSampleRate: rate,
            actualChannels: channels,
            micDelay: 0,
        )
        let recording = try buildRecording(
            from: result,
            recordingsDir: recDir,
            timestamp: stem,
            recordingStartDate: .distantPast,
            format: CaptureFormat(
                requestedChannels: channels,
                requestedRate: rate,
                targetRate: AudioConstants.targetSampleRate,
            ),
        )
        return recording.mixPath
    }

    /// Scan `dir` for crashed recordings (see `crashedRecordingStems`) and
    /// re-mix each. Returns the count recovered; ones that can't be re-mixed
    /// (e.g. a 0-byte temp) are left for `cleanupTempFiles`. Runs from the
    /// launch queue-build (the first watch-start / enqueue), before
    /// `recoverOrphanedRecordings` enqueues the recovered `_mix.wav`.
    ///
    /// `minAge` skips a `.tmp` still being written by an in-progress recording
    /// (its mtime is recent; a crashed recording's temp predates the relaunch
    /// gap). The queue-build Task that calls this is fired by a watch-start
    /// immediately before the loop may begin a new recording, so the guard is
    /// load-bearing — not cosmetic.
    @discardableResult
    nonisolated static func recoverCrashedRecordings(
        in dir: URL = AppPaths.recordingsDir,
        minAge: TimeInterval = 30,
    ) -> Int {
        let fm = FileManager.default
        let names = (try? fm.contentsOfDirectory(atPath: dir.path)) ?? []
        let cutoff = Date().addingTimeInterval(-minAge)
        var recovered = 0
        for stem in crashedRecordingStems(in: names) {
            // Freshness is read off the TRACKS, not the marker: the marker is
            // written once at start, so an hour into a live recording it looks
            // ancient while the tracks are still growing. Re-mixing under a
            // running writer is what this guard exists to prevent.
            if lastTrackWrite(stem: stem, in: dir).map({ $0 > cutoff }) ?? true { continue }
            do {
                let mix = try recoverCrashedRecording(stem: stem, in: dir)
                // The mix alone would already stop `crashedRecordingStems` from
                // re-reporting this stem; the marker goes too so a recovery
                // whose mix is later moved into the output folder cannot look
                // like a fresh crash.
                try? fm.removeItem(at: inProgressMarker(stem: stem, in: dir))
                logger.info("Recovered crashed recording: \(mix.lastPathComponent)")
                recovered += 1
            } catch {
                // Error left redacted: for re-imports the stem is title-derived,
                // and a recovery file error embeds that filename in its description.
                logger.warning("Could not recover crashed recording \(stem): \(error.localizedDescription)")
            }
        }
        return recovered
    }

    /// Optional live-buffer sinks installed by an external live transcription
    /// controller. Set before calling `start(...)` — the next capture session
    /// hands a copy of every mic/app buffer to these sinks alongside the
    /// existing file write. Default nil = batch-only behaviour preserved.
    var micLiveSink: LiveAudioSink?
    var appLiveSink: LiveAudioSink?

    /// Start recording whichever channels `source` asks for.
    func start(
        source: RecordingSource,
        micDeviceUID: String? = nil,
        debugLogging: Bool = false,
    ) throws {
        guard !isRecording else { return }
        // The compiler no longer needs this — the 14.2 floor is enforced inside
        // the factory, the only path to a real session. It is here so that the
        // rejection is the FIRST thing that happens: below this line the start
        // creates a directory, writes a marker and walks the target's process
        // tree, so without it a 14.1 user gets whichever of those fails first
        // (a filesystem error, say) instead of the one message naming their OS,
        // and pays a full process enumeration per detected meeting for a
        // session that can never open.
        guard #available(macOS 14.2, *) else {
            throw RecorderError.unsupportedOS
        }

        try FileManager.default.createDirectory(at: recordingsDir, withIntermediateDirectories: true)

        let ts = Self.timestamp()
        startTimestamp = ts

        // Written before capture opens and removed in `stop()`, so a surviving
        // one means this process died mid-recording. The app temp says the same
        // for a recording that taps an app; this covers the ones that do not.
        try? Data().write(to: Self.inProgressMarker(stem: ts, in: recordingsDir))

        // ── AudioTapLib capture session ──
        // A source with no target opens no tap at all, so it gets neither a
        // temp file nor a PID list; the session then has the mic as its only
        // channel and treats a mic failure as terminal.
        let appTempURL: URL? = source.capturesAppAudio
            ? recordingsDir.appendingPathComponent("\(ts)\(RecordingFileSuffix.appRaw)")
            : nil
        let micURL: URL? = source.capturesMicrophone
            ? recordingsDir.appendingPathComponent("\(ts)\(RecordingFileSuffix.mic)")
            : nil

        // Electron/WebView2 apps (Teams 2.x, Slack, Discord) render call
        // audio in helper/renderer children rather than the shell process
        // the OS sees as the window owner. Tap the whole bundle tree so we
        // catch whichever child holds the audio handle; fall back to the
        // root PID alone if the bundle URL is unavailable.
        let effectivePids = source.appPID.map { Self.resolveTapPIDs(rootPID: $0) } ?? []

        let session: any AudioCapturing
        do {
            session = try makeCaptureSession(AudioCaptureConfiguration(
                pids: effectivePids,
                appOutputURL: appTempURL,
                micOutputURL: micURL,
                sampleRate: recordRate,
                channels: appChannels,
                micDeviceUID: (micDeviceUID?.isEmpty ?? true) ? nil : micDeviceUID,
                debugLogging: debugLogging,
                appLiveSink: appLiveSink,
                micLiveSink: micLiveSink,
            ))
            try session.start()
        } catch {
            // Nothing else would ever remove it: `stop()` is unreachable with
            // `isRecording` still false, and the cleanup pass below keys on
            // tracks this start never created. The marker means "interrupted
            // mid-recording", and a start that never opened is not that.
            try? FileManager.default.removeItem(at: Self.inProgressMarker(stem: ts, in: recordingsDir))
            startTimestamp = nil
            throw error
        }
        captureSession = session

        isRecording = true
        recordingStartDate = Date()

        logger.info("Recording started: \(source.logDescription), \(self.recordRate) Hz, \(self.appChannels)ch")
    }

    /// Stop recording and produce a mixed WAV. The capture session is the only
    /// hardware-bound part; everything after `session.stop()` is delegated to
    /// the testable `buildRecording`.
    func stop() throws -> RecordingResult {
        guard isRecording else {
            throw RecorderError.notRecording
        }

        isRecording = false

        // Stop capture session and get result
        guard let session = captureSession else {
            throw RecorderError.noAudioData
        }
        let captureResult = session.stop()
        captureSession = nil

        let ts = startTimestamp ?? Self.timestamp()
        startTimestamp = nil

        // The capture session writes 16 kHz mono (in-IOProc resample), so that —
        // not the device-facing recordRate/appChannels — is the expected file
        // format; a buildRecording mismatch warning then means the resampler
        // fallback wrote raw native-rate audio.
        let recording = try Self.buildRecording(
            from: captureResult,
            recordingsDir: recordingsDir,
            timestamp: ts,
            recordingStartDate: recordingStartDate,
            format: CaptureFormat(requestedChannels: 1, requestedRate: targetRate, targetRate: targetRate),
        )

        // Dropped only once the mix exists, exactly where `buildRecording`
        // drops the raw app temp. A stop whose mix write fails has not
        // finished anything, and the failure (a full disk, say) usually
        // survives to the next launch: keeping the marker lets that launch
        // re-mix from the surviving tracks, which is what the app-audio path
        // has always got from its temp. The mix itself is what stops a
        // completed recording from being recovered twice.
        try? FileManager.default.removeItem(at: Self.inProgressMarker(stem: ts, in: recordingsDir))
        return recording
    }

    /// Resolve the PID set to tap for a meeting-matched root PID.
    ///
    /// Returns `[rootPID]` alone when the running-application bundle URL is
    /// unavailable (command-line tool, detached process) or enumeration
    /// finds no PIDs under it. Otherwise returns every PID under the bundle,
    /// prepending the root if enumeration somehow missed it — order matters
    /// for the aggregate device's cosmetic name tag (root first).
    static func resolveTapPIDs(rootPID: pid_t) -> [pid_t] {
        // Safari's audio runs in WebKit XPC outside Safari.app — see ProcessResponsibility.tapPIDs.
        ProcessResponsibility.tapPIDs(rootPID: rootPID, bundleDerived: resolveTapPIDs(
            rootPID: rootPID,
            bundleURL: NSRunningApplication(processIdentifier: rootPID)?.bundleURL,
            enumerate: ProcessTreeEnumerator.pidsRooted(in:),
        ))
    }

    /// Test seam — same PID-set decision as `resolveTapPIDs(rootPID:)` but with
    /// the running-app bundle lookup + child-PID enumeration injected, so the
    /// empty-enumeration fallback, the already-includes-root passthrough, and the
    /// load-bearing root-prepend ordering (aggregate device name tag; #84) are
    /// unit-testable without real running processes.
    static func resolveTapPIDs(
        rootPID: pid_t,
        bundleURL: URL?,
        enumerate: (URL) -> [pid_t],
    ) -> [pid_t] {
        guard let bundleURL else { return [rootPID] }
        let enumerated = enumerate(bundleURL)
        // Empty `enumerated` needs no guard: it falls through to `[rootPID] + []`, the root alone.
        return enumerated.contains(rootPID) ? enumerated : [rootPID] + enumerated
    }

    /// Downmix interleaved multi-channel audio to mono. Passthrough if already
    /// mono. Delegates to the AudioTapLib implementation so the averaging logic
    /// lives once (the capture-time resampler uses the same function).
    nonisolated static func downmixToMono(_ samples: [Float], channels: Int) -> [Float] {
        AudioTapLib.downmixToMono(samples, channels: channels)
    }

    /// Cross-check the device-reported sample rate against raw file size and mic duration.
    /// Returns the corrected rate (snapped to standard), or the device rate if cross-check
    /// is unavailable or agrees.
    nonisolated static func crossCheckAppRate(
        deviceRate: Int,
        appRawBytes: Int,
        appChannels: Int,
        micDurationSeconds: Double?,
        micDelay: TimeInterval,
    ) -> Int {
        guard let micDuration = micDurationSeconds, micDuration > 3.0 else {
            return deviceRate
        }
        let appDuration = micDuration + micDelay
        guard appDuration > 3.0 else { return deviceRate }

        guard let inferred = SampleRateQuery.inferRateFromDuration(
            rawBytes: appRawBytes,
            bytesPerSample: MemoryLayout<Float>.size,
            channels: max(appChannels, 1),
            durationSeconds: appDuration,
        ) else { return deviceRate }

        let snapped = SampleRateQuery.snapToStandardRate(inferred)

        // Only override if significantly different (> 5% deviation)
        let deviation = abs(Double(snapped - deviceRate)) / Double(max(deviceRate, 1))
        if deviation > 0.05 {
            logger.warning("Rate cross-check: device=\(deviceRate), inferred=\(inferred), snapped=\(snapped) — overriding")
            return snapped
        }
        return deviceRate
    }

    // Pinned Gregorian/POSIX: these stems are the final user-visible filenames
    // in record-only mode, so the year must not localize into a regional calendar.
    private static let timestampFormatter = DateFormatter.filenameStamp("yyyyMMdd_HHmmss")

    private static func timestamp() -> String {
        timestampFormatter.string(from: Date())
    }
}

enum RecorderError: LocalizedError {
    case notRecording
    case noAudioData
    case unsupportedOS
    case permissionDenied(String)

    var errorDescription: String? {
        switch self {
        case .notRecording: "Not currently recording"
        case .noAudioData: "No audio data recorded"
        case .unsupportedOS: "macOS 14.2+ required for audio capture"
        case let .permissionDenied(reason): "Permission problem: \(reason)"
        }
    }
}
