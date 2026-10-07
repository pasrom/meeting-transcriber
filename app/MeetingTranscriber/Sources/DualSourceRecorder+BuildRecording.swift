import AudioTapLib
import AVFoundation
import Foundation
import os.log

private let logger = Logger(subsystem: AppPaths.logSubsystem, category: "DualSourceRecorder")

/// Turning a finished capture session into the files the pipeline consumes.
///
/// Split out of `DualSourceRecorder.swift` to keep that file under the line
/// cap, along a seam the code already had: everything here is pure file
/// processing with no capture session and no `@available` gate, which is what
/// makes it testable against fixture WAVs.
extension DualSourceRecorder {
    /// Report what the tap actually negotiated against what was asked for.
    ///
    /// Called only where a tap was opened. Without one the rate and channel
    /// count fall back to the *configured* values, so these lines would blame a
    /// mono USB device and a renegotiated rate for hardware nothing touched, in
    /// the log a support bundle is read from.
    nonisolated private static func logAppFormat(channels: Int, rate: Int, format: CaptureFormat) {
        logger.info("App audio: \(channels)ch, \(rate) Hz (requested: \(format.requestedChannels)ch, \(format.requestedRate) Hz)")
        if channels != format.requestedChannels {
            logger.warning("App audio channel count differs: actual=\(channels), expected=\(format.requestedChannels) — mono USB device?")
        }
        if rate != format.requestedRate {
            logger.warning("App audio rate differs: actual=\(rate), expected=\(format.requestedRate) — USB device may have negotiated different rate")
        }
    }

    /// Write the mix through `write` into a staging file next to `mixPath`
    /// and rename it into place only once `write` has returned, so `mixPath`
    /// exists only complete (see `RecordingFileSuffix.mixStaging`). A throw
    /// leaves no mix; the staging file it leaves is removed here, or by
    /// `removeStaleMixStaging` if the process ends first. `rename(2)`
    /// replaces an existing mix atomically.
    ///
    /// The staging name is unique per write, not per stem: two re-mixes of
    /// one stem can overlap (every queue rebuild starts a staging recovery),
    /// and with a shared name one write unlinked the other's file and that
    /// one's rename then put a half-written file in place as the mix.
    nonisolated static func writeMixAtomically(to mixPath: URL, _ write: (URL) throws -> Void) throws {
        let name = mixPath.lastPathComponent
        let stem = name.hasSuffix(RecordingFileSuffix.mix) ? String(name.dropLast(RecordingFileSuffix.mix.count)) : name
        let staging = mixPath.deletingLastPathComponent()
            .appendingPathComponent("\(stem).\(UUID().uuidString)\(RecordingFileSuffix.mixStaging)")
        do {
            try write(staging)
        } catch {
            try? FileManager.default.removeItem(at: staging)
            throw error
        }
        guard rename(staging.path, mixPath.path) == 0 else {
            let code = POSIXErrorCode(rawValue: errno) ?? .EIO
            try? FileManager.default.removeItem(at: staging)
            throw CocoaError(.fileWriteUnknown, userInfo: [NSUnderlyingErrorKey: POSIXError(code)])
        }
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
        recordingStartDate: Date,
        format: CaptureFormat,
    ) throws -> RecordingResult {
        let micDelay = captureResult.micDelay
        let actualChannels = captureResult.actualChannels

        // Query raw file size before it gets deleted — needed for rate cross-check.
        // nil means no tap was ever opened (a mic-only recording), which is not
        // the same as a tap that opened and wrote nothing.
        let tempURL = captureResult.appAudioFileURL
        let appRawBytes = tempURL.flatMap { url in
            try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int
        } ?? 0

        // Cross-check rate using mic duration. Only the app track has a rate to
        // second-guess, so with no temp this opens (and later re-opens) the mic
        // file for a correction that cannot apply.
        let micDuration: Double? = if tempURL != nil,
                                      let micURL = captureResult.micAudioFileURL,
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

        if tempURL != nil {
            logAppFormat(channels: actualChannels, rate: actualRate, format: format)
        }

        // ── Load mic audio ──
        var micPath: URL?
        var micSamples: [Float] = []
        let expectedMicPath = captureResult.micAudioFileURL

        if let expectedMicPath,
           FileManager.default.fileExists(atPath: expectedMicPath.path),
           (try? FileManager.default.attributesOfItem(atPath: expectedMicPath.path)[.size] as? Int) ?? 0 > 44 {
            // `try?`, not `try`, and that is load-bearing now that this block
            // runs before the app WAV is written. A throw here used to leave a
            // finished `_app.wav` behind; it no longer would, and the next
            // launch runs recovery (which retries the same corrupt file and
            // throws again) and then `cleanupTempFiles`, which deletes the raw
            // temp once it is older than thirty seconds. A microphone whose
            // header cannot be read would take the app audio with it. Falling
            // through to the app-only path is also how this block already
            // treats a missing or too-small file.
            if let micAudioFile = try? AVAudioFile(forReading: expectedMicPath),
               let loaded = try? AudioMixer.loadAudioFileAsFloat32(url: expectedMicPath) {
                micSamples = loaded
                micPath = expectedMicPath
                let micFileRate = Int(micAudioFile.processingFormat.sampleRate)
                logger.info("Mic audio loaded: \(expectedMicPath.lastPathComponent) (\(micFileRate) Hz)")
            } else {
                logger.warning("Mic audio could not be read — continuing with app audio only")
            }
        }

        // A microphone that started before the app tap makes `micDelay`
        // negative, which is what opening the microphone first does on every
        // dual-source recording. Rather than teach a dozen consumers a new sign,
        // the app track is padded here and the reported delay becomes zero, so
        // both files and every timeline derived from them share one origin.
        let normalisation = MicDelayNormalisation.decide(
            rawDelay: micDelay, micLoaded: micPath != nil, sampleRate: format.targetRate,
        )
        if micDelay != 0 {
            // Both numbers, because normalisation makes the reported one zero
            // and the measured delta would otherwise survive nowhere: not in the
            // result, the job or the sidecar. It is the size of the tap's
            // lateness, which is the thing issue #693 is about.
            logger.info(
                "Mic delay: measured \(micDelay)s, reported \(normalisation.reportedDelay)s, pad \(normalisation.padFrames) frames",
            )
        }

        // Loaded before the app track is written, not after, because whether a
        // microphone track exists decides whether the app track is padded below,
        // and the app WAV is on disk by the end of that block.
        // ── Convert app audio from temp file to Float32 mono ──
        var appPath: URL?
        var appSamples: [Float] = []
        var appSamples16k: [Float] = []

        if let tempURL, appRawBytes > 0 {
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
            if normalisation.padFrames > 0 {
                // Released first: on the production path the temp is already
                // 16 kHz mono, so `floats`, `appSamples` and `appSamples16k`
                // share one buffer, and the concatenation below would otherwise
                // hold a second full copy of the track alive to the end of the
                // function. About 220 MB per recorded hour at 16 kHz Float32.
                appSamples = []
                appSamples16k = [Float](repeating: 0, count: normalisation.padFrames) + appSamples16k
            }
            let appFile = recDir.appendingPathComponent("\(ts)\(RecordingFileSuffix.app)")
            try AudioMixer.saveWAV(samples: appSamples16k, sampleRate: format.targetRate, url: appFile)
            appPath = appFile
            logger.info("App audio saved: \(appFile.lastPathComponent) (\(actualRate)→\(format.targetRate) Hz)")
        } else if let tempURL, FileManager.default.fileExists(atPath: tempURL.path) {
            // Clean up empty temp file left by failed app audio capture
            try? FileManager.default.removeItem(at: tempURL)
            logger.warning("App audio capture produced 0 bytes — temp file cleaned up")
        }

        // Only a session that asked for an app track can have failed to get
        // one. A mic-only recording has no tap to blame and must not log as if
        // something went wrong.
        if appPath == nil, tempURL != nil {
            logger.warning("No app audio captured — capture may have failed to create the tap")
        }

        // ── Mix via AudioMixer ──
        // Both app and mic are already at 16kHz at this point.
        let mixRate = format.targetRate
        let mixPath = recDir.appendingPathComponent("\(ts)\(RecordingFileSuffix.mix)")

        guard (appPath != nil && micPath != nil) || !appSamples16k.isEmpty || !micSamples.isEmpty else {
            throw RecorderError.noAudioData
        }
        try writeMixAtomically(to: mixPath) { staging in
            if let app = appPath, let mic = micPath {
                // Delegate mute masking, echo suppression, delay alignment, and mixing
                try AudioMixer.mix(
                    appAudioPath: app,
                    micAudioPath: mic,
                    outputPath: staging,
                    micDelay: normalisation.reportedDelay,
                    sampleRate: mixRate,
                )
            } else if !appSamples16k.isEmpty {
                try AudioMixer.saveWAV(samples: appSamples16k, sampleRate: mixRate, url: staging)
            } else {
                try AudioMixer.saveWAV(samples: micSamples, sampleRate: mixRate, url: staging)
            }
        }

        logger.info("Mix saved: \(mixPath.lastPathComponent)")

        // The raw app temp is the canonical recovery source on the crash-
        // recovery path. Drop it only now that a durable mix exists, so a
        // failure anywhere above leaves it intact for the next recovery attempt.
        if let tempURL, appRawBytes > 0 {
            try? FileManager.default.removeItem(at: tempURL)
        }

        return RecordingResult(
            mixPath: mixPath,
            appPath: appPath,
            micPath: micPath,
            micDelay: normalisation.reportedDelay,
            recordingStartDate: recordingStartDate,
        )
    }

    /// Delete mix staging files a write cut off by the process exit left
    /// behind. Runs after crash recovery, which re-mixes a rescuable stem
    /// under a staging name of its own, so what is left is litter whether or
    /// not the stem got a mix. `cutoff` spares a write still in progress.
    nonisolated static func removeStaleMixStaging(in entries: [URL], olderThan cutoff: Date) {
        let fm = FileManager.default
        for file in entries where file.lastPathComponent.hasSuffix(RecordingFileSuffix.mixStaging) {
            if let mtime = (try? fm.attributesOfItem(atPath: file.path)[.modificationDate]) as? Date,
               mtime > cutoff { continue }
            try? fm.removeItem(at: file)
        }
    }
}
