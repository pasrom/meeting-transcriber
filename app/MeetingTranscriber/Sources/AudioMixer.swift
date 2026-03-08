import Accelerate
import AVFoundation
import Foundation
import os.log

private let logger = Logger(subsystem: AppPaths.logSubsystem, category: "AudioMixer")

/// Audio mixing, echo suppression, mute masking, and resampling utilities.
struct AudioMixer {

    // MARK: - Mix

    /// Mix app and mic audio tracks into a single mono WAV.
    ///
    /// Applies mute masking, echo suppression, delay alignment,
    /// then averages the two tracks.
    static func mix(
        appAudioPath: URL,
        micAudioPath: URL,
        outputPath: URL,
        micDelay: TimeInterval = 0,
        muteTimeline: [MuteTransition] = [],
        recordingStart: TimeInterval = 0,
        sampleRate: Int = 48000
    ) throws {
        var appSamples = try loadWAVAsFloat32(url: appAudioPath)
        var micSamples = try loadWAVAsFloat32(url: micAudioPath)

        // Apply mute mask to mic (zero samples during muted periods)
        if !muteTimeline.isEmpty {
            applyMuteMask(
                samples: &micSamples,
                timeline: muteTimeline,
                sampleRate: sampleRate,
                micDelay: micDelay,
                recordingStart: recordingStart
            )
        }

        // Apply echo suppression
        if !appSamples.isEmpty && !micSamples.isEmpty {
            suppressEcho(
                appSamples: appSamples,
                micSamples: &micSamples,
                sampleRate: sampleRate,
                micDelay: micDelay
            )
        }

        // Align by mic delay (shift mic samples)
        if micDelay > 0 {
            let delaySamples = Int(micDelay * Double(sampleRate))
            if delaySamples > 0 && delaySamples < micSamples.count {
                // Mic started later: prepend zeros
                micSamples = [Float](repeating: 0, count: delaySamples) + micSamples
            }
        } else if micDelay < 0 {
            let delaySamples = Int(-micDelay * Double(sampleRate))
            if delaySamples > 0 && delaySamples < appSamples.count {
                // App started later: prepend zeros to app
                appSamples = [Float](repeating: 0, count: delaySamples) + appSamples
            }
        }

        // Average the two tracks
        let mixed = mixTracks(appSamples, micSamples)

        try saveWAV(samples: mixed, sampleRate: sampleRate, url: outputPath)
        logger.info("Mixed audio saved: \(outputPath.lastPathComponent)")
    }

    /// Average two audio tracks. If lengths differ, extend with the longer track's tail.
    static func mixTracks(_ a: [Float], _ b: [Float]) -> [Float] {
        if a.isEmpty { return b }
        if b.isEmpty { return a }

        let minLen = min(a.count, b.count)
        var result = [Float](repeating: 0, count: max(a.count, b.count))

        // Average overlapping region
        for i in 0..<minLen {
            result[i] = (a[i] + b[i]) / 2
        }

        // Append tail of longer track
        if a.count > minLen {
            for i in minLen..<a.count { result[i] = a[i] }
        } else if b.count > minLen {
            for i in minLen..<b.count { result[i] = b[i] }
        }

        return result
    }

    // MARK: - Mute Masking

    /// Zero out mic samples during muted periods.
    static func applyMuteMask(
        samples: inout [Float],
        timeline: [MuteTransition],
        sampleRate: Int,
        micDelay: TimeInterval = 0,
        recordingStart: TimeInterval = 0
    ) {
        guard !timeline.isEmpty, !samples.isEmpty else { return }

        var mutedRanges: [(start: Int, end: Int)] = []
        var muteStart: TimeInterval?

        for transition in timeline {
            let relativeTime = transition.timestamp - recordingStart - micDelay
            let sampleIndex = Int(relativeTime * Double(sampleRate))

            if transition.isMuted {
                muteStart = Double(max(0, sampleIndex))
            } else if let start = muteStart {
                mutedRanges.append((start: Int(start), end: max(Int(start), sampleIndex)))
                muteStart = nil
            }
        }

        // If still muted at end, mute until end of recording
        if let start = muteStart {
            mutedRanges.append((start: Int(start), end: samples.count))
        }

        for range in mutedRanges {
            let clamped = max(0, range.start)..<min(samples.count, range.end)
            for i in clamped {
                samples[i] = 0
            }
        }

        let maskedSamples = mutedRanges.reduce(0) { $0 + max(0, $1.end - $1.start) }
        logger.debug("Mute mask: zeroed \(maskedSamples) samples in \(mutedRanges.count) ranges")
    }

    // MARK: - Echo Suppression

    /// RMS-based echo suppression: gate mic where app has energy.
    ///
    /// Uses 20ms analysis windows with asymmetric margins:
    /// - 2 windows before (40ms lookahead)
    /// - 10 windows after (200ms decay)
    static func suppressEcho(
        appSamples: [Float],
        micSamples: inout [Float],
        sampleRate: Int,
        micDelay: TimeInterval = 0,
        threshold: Float = 0.01
    ) {
        let windowSize = sampleRate / 50  // 20ms windows
        guard windowSize > 0 else { return }

        let marginBefore = 2   // 40ms
        let marginAfter = 10   // 200ms

        // Compute RMS energy per window for app audio
        let appWindowCount = appSamples.count / windowSize
        guard appWindowCount > 0 else { return }

        var appRMS = [Float](repeating: 0, count: appWindowCount)
        for i in 0..<appWindowCount {
            let start = i * windowSize
            let end = min(start + windowSize, appSamples.count)
            var sumSq: Float = 0
            for j in start..<end {
                sumSq += appSamples[j] * appSamples[j]
            }
            appRMS[i] = sqrt(sumSq / Float(end - start))
        }

        // Build gate mask: true = suppress
        var gateMask = [Bool](repeating: false, count: appWindowCount)
        for i in 0..<appWindowCount {
            if appRMS[i] > threshold {
                let lo = max(0, i - marginBefore)
                let hi = min(appWindowCount - 1, i + marginAfter)
                for j in lo...hi {
                    gateMask[j] = true
                }
            }
        }

        // Apply delay offset
        let delaySamples = Int(micDelay * Double(sampleRate))
        let delayWindows = delaySamples / windowSize

        // Apply gate mask to mic samples
        let micWindowCount = micSamples.count / windowSize
        for i in 0..<micWindowCount {
            let appIdx = i + delayWindows
            if appIdx >= 0 && appIdx < appWindowCount && gateMask[appIdx] {
                let start = i * windowSize
                let end = min(start + windowSize, micSamples.count)
                for j in start..<end {
                    micSamples[j] = 0  // full suppression
                }
            }
        }
    }

    // MARK: - Resampling

    /// Resample audio from one sample rate to another using linear interpolation.
    /// For production use, consider vDSP_desamp or polyphase resampling.
    static func resample(_ samples: [Float], from sourceRate: Int, to targetRate: Int) -> [Float] {
        guard sourceRate != targetRate, !samples.isEmpty else { return samples }

        let ratio = Double(targetRate) / Double(sourceRate)
        let outputCount = Int(Double(samples.count) * ratio)
        var output = [Float](repeating: 0, count: outputCount)

        for i in 0..<outputCount {
            let srcIdx = Double(i) / ratio
            let lo = Int(srcIdx)
            let hi = min(lo + 1, samples.count - 1)
            let frac = Float(srcIdx - Double(lo))
            output[i] = samples[lo] * (1 - frac) + samples[hi] * frac
        }

        return output
    }

    // MARK: - Convenience

    /// Load a WAV file, resample to a target rate, and save to a new file.
    static func resampleFile(from source: URL, to destination: URL, targetRate: Int = 16000) throws {
        let file = try AVAudioFile(forReading: source)
        let sourceRate = Int(file.processingFormat.sampleRate)
        let samples = try loadWAVAsFloat32(url: source)
        let resampled = resample(samples, from: sourceRate, to: targetRate)
        try saveWAV(samples: resampled, sampleRate: targetRate, url: destination)
    }

    // MARK: - WAV I/O

    /// Load a WAV file as mono Float32 samples.
    static func loadWAVAsFloat32(url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        let frameCount = AVAudioFrameCount(file.length)
        guard frameCount > 0 else { return [] }

        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
            throw AudioMixerError.bufferCreationFailed
        }
        try file.read(into: buffer)

        guard let floatData = buffer.floatChannelData else {
            throw AudioMixerError.noFloatData
        }

        let channelCount = Int(format.channelCount)
        let sampleCount = Int(buffer.frameLength)

        if channelCount == 1 {
            return Array(UnsafeBufferPointer(start: floatData[0], count: sampleCount))
        }

        // Stereo → mono (average channels)
        var mono = [Float](repeating: 0, count: sampleCount)
        for ch in 0..<channelCount {
            let channelPtr = floatData[ch]
            for i in 0..<sampleCount {
                mono[i] += channelPtr[i]
            }
        }
        let scale = 1.0 / Float(channelCount)
        for i in 0..<sampleCount {
            mono[i] *= scale
        }
        return mono
    }

    /// Save Float32 mono samples to a 16-bit PCM WAV file.
    static func saveWAV(samples: [Float], sampleRate: Int, url: URL) throws {
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Double(sampleRate),
            channels: 1,
            interleaved: false
        ) else {
            throw AudioMixerError.formatCreationFailed
        }

        let file = try AVAudioFile(
            forWriting: url,
            settings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: sampleRate,
                AVNumberOfChannelsKey: 1,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
            ]
        )

        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)) else {
            throw AudioMixerError.bufferCreationFailed
        }
        buffer.frameLength = AVAudioFrameCount(samples.count)

        let dst = buffer.floatChannelData![0]
        samples.withUnsafeBufferPointer { src in
            dst.initialize(from: src.baseAddress!, count: samples.count)
        }

        try file.write(from: buffer)
    }
}

enum AudioMixerError: LocalizedError {
    case bufferCreationFailed
    case noFloatData
    case formatCreationFailed

    var errorDescription: String? {
        switch self {
        case .bufferCreationFailed: return "Failed to create audio buffer"
        case .noFloatData: return "Audio buffer has no float data"
        case .formatCreationFailed: return "Failed to create audio format"
        }
    }
}
