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

        if micDelay != 0 {
            logger.info("Mic delay: \(micDelay)s")
        }
        if tempURL != nil {
            logAppFormat(channels: actualChannels, rate: actualRate, format: format)
        }

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
        if let tempURL, appRawBytes > 0 {
            try? FileManager.default.removeItem(at: tempURL)
        }

        return RecordingResult(
            mixPath: mixPath,
            appPath: appPath,
            micPath: micPath,
            micDelay: micDelay,
            recordingStartDate: recordingStartDate,
        )
    }
}
