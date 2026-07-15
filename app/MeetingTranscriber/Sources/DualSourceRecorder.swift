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
    let recordingStart: TimeInterval // ProcessInfo.systemUptime
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

/// Abstraction for recording, enabling mock injection in tests.
@MainActor
protocol RecordingProvider {
    func start(appPID: pid_t, noMic: Bool, micDeviceUID: String?, debugLogging: Bool) throws
    func stop() throws -> RecordingResult

    /// Instantaneous app-audio level in dBFS. -120 when no capture session is
    /// active or the tap stopped delivering buffers in the last 0.5 s.
    /// Drives the menu-bar asymmetric-silence indicator. Default: -120
    /// (mocks that don't simulate audio levels stay silent).
    var appLevelDBFS: Double { get }

    /// Instantaneous mic level in dBFS, with the same semantics as
    /// `appLevelDBFS`.
    var micLevelDBFS: Double { get }
}

extension RecordingProvider {
    var appLevelDBFS: Double {
        -120
    }

    var micLevelDBFS: Double {
        -120
    }
}

/// Orchestrates app audio capture (via AudioTapLib) + mic recording, then mixes.
@MainActor
@Observable
class DualSourceRecorder: RecordingProvider {
    @available(macOS 14.2, *)
    private var captureSession: AudioCaptureSession? {
        get { _captureSession as? AudioCaptureSession }
        set { _captureSession = newValue }
    }

    // Type-erased storage to avoid @available on stored properties
    private var _captureSession: AnyObject?
    private(set) var isRecording = false
    private(set) var recordingStartTime: TimeInterval = 0
    private var startTimestamp: String?

    var appLevelDBFS: Double {
        guard #available(macOS 14.2, *) else { return -120 }
        return captureSession?.appLevelDBFS ?? -120
    }

    var micLevelDBFS: Double {
        guard #available(macOS 14.2, *) else { return -120 }
        return captureSession?.micLevelDBFS ?? -120
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

    /// Recordings directory.
    static var recordingsDir: URL {
        AppPaths.recordingsDir
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
    ) {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: recordingsDir,
            includingPropertiesForKeys: nil,
        ) else { return }
        let cutoff = Date().addingTimeInterval(-minAge)

        for file in entries where RecordingFileSuffix.stripAppRaw(from: file.lastPathComponent) != nil {
            if let mtime = (try? fm.attributesOfItem(atPath: file.path)[.modificationDate]) as? Date,
               mtime > cutoff { continue }
            try? fm.removeItem(at: file)
            logger.info("Removed orphaned temp file: \(file.lastPathComponent)")
        }
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
            guard let stem = RecordingFileSuffix.stripAppRaw(from: name) else { continue }
            guard !mixStems.contains(stem), seen.insert(stem).inserted else { continue }
            stems.append(stem)
        }
        return stems
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
        guard let temp = crashedTemp(stem: stem, in: recDir) else {
            throw RecorderError.noAudioData
        }
        let micWav = recDir.appendingPathComponent(stem + RecordingFileSuffix.mic)
        let hasMic = FileManager.default.fileExists(atPath: micWav.path)
        if hasMic { _ = try? WavHeaderRepair.repairIfNeeded(at: micWav) }

        let rate = temp.isLegacy ? defaultRecordRate : AudioConstants.targetSampleRate
        let channels = temp.isLegacy ? defaultAppChannels : 1
        let result = AudioCaptureResult(
            appAudioFileURL: temp.url,
            micAudioFileURL: hasMic ? micWav : nil,
            actualSampleRate: rate,
            actualChannels: channels,
            micDelay: 0,
        )
        let recording = try buildRecording(
            from: result,
            recordingsDir: recDir,
            timestamp: stem,
            recordingStart: 0,
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
            guard let temp = crashedTemp(stem: stem, in: dir) else { continue }
            if let mtime = (try? fm.attributesOfItem(atPath: temp.url.path)[.modificationDate]) as? Date,
               mtime > cutoff { continue }
            do {
                let mix = try recoverCrashedRecording(stem: stem, in: dir)
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

    /// Start recording app audio and optionally mic.
    func start(
        appPID: pid_t,
        noMic: Bool = false,
        micDeviceUID: String? = nil,
        debugLogging: Bool = false,
    ) throws {
        guard !isRecording else { return }
        guard #available(macOS 14.2, *) else {
            throw RecorderError.unsupportedOS
        }

        let recDir = Self.recordingsDir
        try FileManager.default.createDirectory(at: recDir, withIntermediateDirectories: true)

        let ts = Self.timestamp()
        startTimestamp = ts

        // ── AudioTapLib capture session ──
        let appTempURL = recDir.appendingPathComponent("\(ts)\(RecordingFileSuffix.appRaw)")
        let micURL: URL? = noMic ? nil : recDir.appendingPathComponent("\(ts)\(RecordingFileSuffix.mic)")

        // Electron/WebView2 apps (Teams 2.x, Slack, Discord) render call
        // audio in helper/renderer children rather than the shell process
        // the OS sees as the window owner. Tap the whole bundle tree so we
        // catch whichever child holds the audio handle; fall back to the
        // root PID alone if the bundle URL is unavailable.
        let effectivePids = Self.resolveTapPIDs(rootPID: appPID)

        // Mic device-change e2e (issue #379): inject a one-shot tap fault so the
        // app self-triggers a mid-recording restart with an invalid format and
        // the lane can verify the installTap NSException recovery. Compiled ONLY
        // in the e2e build (run_app.sh -DE2E_FAULT_INJECTION); the fault is
        // physically absent from every shipped binary.
        #if E2E_FAULT_INJECTION
            let micDebugFault: DebugTapFault? = DebugTapFault(triggerRestartAfter: 2)
        #else
            let micDebugFault: DebugTapFault? = nil
        #endif

        let session = AudioCaptureSession(
            pids: effectivePids,
            appOutputURL: appTempURL,
            sampleRate: recordRate,
            channels: appChannels,
            micOutputURL: micURL,
            micDeviceUID: (micDeviceUID?.isEmpty ?? true) ? nil : micDeviceUID,
            debugLogging: debugLogging,
            appLiveSink: appLiveSink,
            micLiveSink: micLiveSink,
            micDebugFault: micDebugFault,
        )
        try session.start()
        captureSession = session

        isRecording = true
        recordingStartTime = ProcessInfo.processInfo.systemUptime

        logger.info("Recording started: PID \(appPID), \(self.recordRate) Hz, \(self.appChannels)ch")
    }

    /// Stop recording and produce a mixed WAV. The capture session is the only
    /// hardware-bound part; everything after `session.stop()` is delegated to
    /// the testable `buildRecording`.
    func stop() throws -> RecordingResult {
        guard isRecording else {
            throw RecorderError.notRecording
        }
        guard #available(macOS 14.2, *) else {
            throw RecorderError.unsupportedOS
        }

        let recordingStart = recordingStartTime
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
        return try Self.buildRecording(
            from: captureResult,
            recordingsDir: Self.recordingsDir,
            timestamp: ts,
            recordingStart: recordingStart,
            format: CaptureFormat(requestedChannels: 1, requestedRate: targetRate, targetRate: targetRate),
        )
    }

    /// Convert a finished `AudioCaptureResult` (raw app `.tmp` + optional mic
    /// WAV) into a mixed 16 kHz `RecordingResult`: cross-check the rate, downmix
    /// + resample the app track, load the mic track, then mix or fall back to a
    /// single track. Pure file-processing — no capture session, no `@available`
    /// gate — so it is unit-testable with fixture files.
    nonisolated static func buildRecording( // swiftlint:disable:this function_body_length
        from captureResult: AudioCaptureResult,
        recordingsDir recDir: URL,
        timestamp ts: String,
        recordingStart: TimeInterval,
        format: CaptureFormat,
    ) throws -> RecordingResult {
        let micDelay = captureResult.micDelay
        let actualChannels = captureResult.actualChannels

        // Query raw file size before it gets deleted — needed for rate cross-check
        let tempURL = captureResult.appAudioFileURL
        let appRawBytes = (try? FileManager.default.attributesOfItem(atPath: tempURL.path)[.size] as? Int) ?? 0

        // Cross-check rate using mic duration (mic file is opened once here, reused below)
        let micDuration: Double? = if let micURL = captureResult.micAudioFileURL,
                                      let micFile = try? AVAudioFile(forReading: micURL),
                                      micFile.processingFormat.sampleRate > 0 {
            Double(micFile.length) / micFile.processingFormat.sampleRate
        } else {
            nil
        }

        // A temp already at the target rate (the in-IOProc resampler's output)
        // has no rate left to second-guess — the duration heuristic could only
        // mis-correct it (e.g. a mic that died mid-recording shortens the
        // reference duration and would re-warp a healthy 16 kHz track). The
        // cross-check still guards the fallback/legacy path where the temp is
        // raw device-rate audio.
        let actualRate = captureResult.actualSampleRate == format.targetRate
            ? captureResult.actualSampleRate
            : crossCheckAppRate(
                deviceRate: captureResult.actualSampleRate,
                appRawBytes: appRawBytes,
                appChannels: actualChannels,
                micDurationSeconds: micDuration,
                micDelay: micDelay,
            )

        if micDelay != 0 {
            logger.info("Mic delay: \(micDelay)s")
        }
        logger.info("App audio: \(actualChannels)ch, \(actualRate) Hz (requested: \(format.requestedChannels)ch, \(format.requestedRate) Hz)")
        if actualChannels != format.requestedChannels {
            logger.warning("App audio channel count differs: actual=\(actualChannels), expected=\(format.requestedChannels) — mono USB device?")
        }
        if actualRate != format.requestedRate {
            logger.warning("App audio rate differs: actual=\(actualRate), expected=\(format.requestedRate) — USB device may have negotiated different rate")
        }

        // ── Convert app audio from temp file to Float32 mono ──
        var appPath: URL?
        var appSamples: [Float] = []
        var appSamples16k: [Float] = []

        if appRawBytes > 0 {
            let raw = try Data(contentsOf: tempURL)

            let floatCount = raw.count / MemoryLayout<Float>.size
            var floats = [Float](repeating: 0, count: floatCount)
            raw.withUnsafeBytes { ptr in
                if let base = ptr.baseAddress {
                    floats.withUnsafeMutableBufferPointer { dest in
                        dest.baseAddress!.initialize( // swiftlint:disable:this force_unwrapping
                            from: base.assumingMemoryBound(to: Float.self),
                            count: floatCount,
                        )
                    }
                }
            }

            appSamples = downmixToMono(floats, channels: actualChannels)

            // Resample to 16kHz and save app track
            appSamples16k = AudioMixer.resample(appSamples, from: actualRate, to: format.targetRate)
            let appFile = recDir.appendingPathComponent("\(ts)\(RecordingFileSuffix.app)")
            try AudioMixer.saveWAV(samples: appSamples16k, sampleRate: format.targetRate, url: appFile)
            appPath = appFile
            logger.info("App audio saved: \(appFile.lastPathComponent) (\(actualRate)→\(format.targetRate) Hz)")
        } else if FileManager.default.fileExists(atPath: tempURL.path) {
            // Clean up empty temp file left by failed app audio capture
            try? FileManager.default.removeItem(at: tempURL)
            logger.warning("App audio capture produced 0 bytes — temp file cleaned up")
        }

        if appPath == nil {
            logger.warning("No app audio captured — capture may have failed to create the tap")
        }

        // ── Load mic audio ──
        var micPath: URL?
        var micSamples: [Float] = []
        let expectedMicPath = captureResult.micAudioFileURL

        if let expectedMicPath,
           FileManager.default.fileExists(atPath: expectedMicPath.path),
           (try? FileManager.default.attributesOfItem(atPath: expectedMicPath.path)[.size] as? Int) ?? 0 > 44 {
            let micAudioFile = try AVAudioFile(forReading: expectedMicPath)
            let micFileRate = Int(micAudioFile.processingFormat.sampleRate)
            micSamples = try AudioMixer.loadAudioFileAsFloat32(url: expectedMicPath)
            micPath = expectedMicPath
            logger.info("Mic audio loaded: \(expectedMicPath.lastPathComponent) (\(micFileRate) Hz)")
        }

        // ── Mix via AudioMixer ──
        // Both app and mic are already at 16kHz at this point.
        let mixRate = format.targetRate
        let mixPath = recDir.appendingPathComponent("\(ts)\(RecordingFileSuffix.mix)")

        if let app = appPath, let mic = micPath {
            // Delegate mute masking, echo suppression, delay alignment, and mixing
            try AudioMixer.mix(
                appAudioPath: app,
                micAudioPath: mic,
                outputPath: mixPath,
                micDelay: micDelay,
                sampleRate: mixRate,
            )
        } else if !appSamples16k.isEmpty {
            try AudioMixer.saveWAV(samples: appSamples16k, sampleRate: mixRate, url: mixPath)
        } else if !micSamples.isEmpty {
            try AudioMixer.saveWAV(samples: micSamples, sampleRate: mixRate, url: mixPath)
        } else {
            throw RecorderError.noAudioData
        }

        logger.info("Mix saved: \(mixPath.lastPathComponent)")

        // The raw app temp is the canonical recovery source on the crash-
        // recovery path. Drop it only now that a durable mix exists, so a
        // failure anywhere above leaves it intact for the next recovery attempt.
        if appRawBytes > 0 {
            try? FileManager.default.removeItem(at: tempURL)
        }

        return RecordingResult(
            mixPath: mixPath,
            appPath: appPath,
            micPath: micPath,
            micDelay: micDelay,
            recordingStart: recordingStart,
        )
    }

    /// Resolve the PID set to tap for a meeting-matched root PID.
    ///
    /// Returns `[rootPID]` alone when the running-application bundle URL is
    /// unavailable (command-line tool, detached process) or enumeration
    /// finds no PIDs under it. Otherwise returns every PID under the bundle,
    /// prepending the root if enumeration somehow missed it — order matters
    /// for the aggregate device's cosmetic name tag (root first).
    static func resolveTapPIDs(rootPID: pid_t) -> [pid_t] {
        resolveTapPIDs(
            rootPID: rootPID,
            bundleURL: NSRunningApplication(processIdentifier: rootPID)?.bundleURL,
            enumerate: ProcessTreeEnumerator.pidsRooted(in:),
        )
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
