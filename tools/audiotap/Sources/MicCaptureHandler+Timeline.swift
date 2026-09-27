@preconcurrency import AVFoundation
import Foundation
import os.log

private let logger = Logger(subsystem: "com.meetingtranscriber.audiotap", category: "MicCaptureTimeline")

/// Wall-clock gap-filling for `MicCaptureHandler`. A device-change restart drops
/// mic audio for the teardown→rebuild gap; without compensation the WAV
/// under-runs and drifts out of sync with the app track (issue #379 follow-up).
/// Extracted to a sibling file so `MicCaptureHandler.swift` stays under the
/// 600-line lint cap — same pattern as `AppAudioCapture+Resampling.swift`.
extension MicCaptureHandler {
    /// Write silence for the gap before `outputFrames` of real audio, so the
    /// output file stays aligned to wall-clock. `when` is the buffer's hardware
    /// presentation time (jitter-free); falls back to the callback clock if the
    /// host time is invalid. The `TimelineAnchor` self-anchors on the first
    /// buffer and bridges restart gaps (it is never reset), so steady-state
    /// capture inserts nothing and only a real gap produces silence.
    func fillTimelineGap(before when: AVAudioTime, outputFrames: Int) {
        let hostTicks = when.isHostTimeValid ? when.hostTime : mach_absolute_time()
        let hostSeconds = machTicksToSeconds(hostTicks)
        let silence = timelineAnchor.silenceFramesBefore(
            hostSeconds: hostSeconds, frameCount: outputFrames,
            arrivedAt: machTicksToSeconds(mach_absolute_time()),
        )
        guard silence > 0, let outputFile else { return }
        Self.writeSilence(frames: silence, to: outputFile)
    }

    /// Let the first buffer of a revived capture bridge the whole stall with
    /// silence, in its own gap fill. Main queue, while the revival's attempt
    /// is out and before any adoption flips the phase to capturing; see
    /// `TimelineAnchor` for why that is what makes the call safe, and
    /// `bridgeNextGap` for what is bridged.
    func armTimelineBridgeForRevival() {
        timelineAnchor.bridgeNextGap()
    }

    /// Anchor the track at the capture's start when it is restarted before it
    /// ever delivered, so it begins where the recording did and the wait is
    /// bridged as silence. Main queue, while the restart's attempt is out;
    /// see `TimelineAnchor.anchorBeforeFirstBuffer`.
    func anchorTimelineIfNothingDelivered() {
        guard firstFrameTime == 0, captureStartTicks != 0,
              timelineAnchor.anchorBeforeFirstBuffer(atHostSeconds: machTicksToSeconds(captureStartTicks))
        else { return }
        timelineOriginTicks = captureStartTicks
    }

    /// Write the silence a pending bridge owes up to now, on the restart
    /// queue before the attempt brings its engine up: a stall bridged on
    /// revival can be an hour, and written by the first revived buffer's
    /// callback it would hold up the capture and live captions for as long
    /// as the write takes.
    ///
    /// One chunk of at most a second at a time, each under `bridgeGate`: the
    /// check that this attempt is still current, the write and the count of
    /// what landed. A stop takes the same lock to close the file, so it waits
    /// for at most the chunk in flight and the next chunk sees the stop; it
    /// used to return while that chunk was still being written, and the
    /// recorder read the track short, or empty with its header not yet
    /// written. A buffer callback of the outgoing engine does not take the
    /// lock; that narrower window is described on `TimelineAnchor`.
    func writePendingTimelineBridge(generation: Int) {
        let target = machTicksToSeconds(mach_absolute_time())
        var total = 0
        while true {
            let chunk: (owed: Int, written: Int)? = bridgeGate.lock.withLock {
                guard arbiter.withLock({ $0.phase == .attemptInFlight(generation: generation) }),
                      let outputFile else { return nil }
                let owed = min(
                    timelineAnchor.pendingBridge(toHostSeconds: target),
                    max(Int(outputFile.processingFormat.sampleRate), 1),
                )
                guard owed > 0 else { return nil }
                bridgeGate.beforeChunk()
                // Right before the write: a stop that gave up waiting has
                // handed the file on, and nothing may land in it after that.
                guard !bridgeGate.isAbandoned else { return nil }
                let written = Self.writeSilence(frames: owed, to: outputFile, logged: false)
                timelineAnchor.noteBridgeWritten(frames: written)
                return (owed, written)
            }
            guard let chunk else { break }
            total += chunk.written
            if chunk.written < chunk.owed { break }
        }
        if Self.shouldLogGapFill(frames: total, sampleRate: Double(timelineAnchor.rate)) {
            logger.info("Mic: bridged \(total) silent frames of the stall to keep the track aligned to wall-clock")
        }
    }

    /// Close the file for `stop()`, once the bridge chunk in flight, if any, is
    /// in it: the recorder opens the microphone track as soon as the stop
    /// returns. Waited for no longer than `bridgeGate.stopWait`, because the
    /// stop runs on the main thread and a write to a stuck volume does not
    /// return: past the bound the stop goes on without the chunk and says so,
    /// and marks the bridge abandoned, so a chunk that has not reached its
    /// write yet never writes. The bridge still holds its own handle until its
    /// chunk is done, so two things can reach the file after the stop, even
    /// once the recorder has moved it: a write already under way cannot be
    /// recalled and lands when the volume answers, at most one chunk of
    /// silence; and releasing the handle rewrites the WAV header's sizes to the
    /// frames written, which happens whether that write ran or not. The track
    /// the recorder reads at the stop can be short, or carry a header that does
    /// not count all of it yet; it mixes a short track as it is and skips one
    /// it cannot read, continuing with the app track. A stuck volume also holds
    /// up the recorder's own writes of the mix to the same folder, so the bound
    /// keeps this wait from adding a freeze of its own, not the app from a
    /// stuck volume.
    func closeFileAfterBridgeChunk() {
        let gate = bridgeGate
        guard gate.lock.lock(before: Date().addingTimeInterval(gate.stopWait)) else {
            logger.error(
                "Mic: the stall's silence did not finish writing within \(gate.stopWait, privacy: .public)s; stopping without it, the microphone track may be short or unreadable",
            )
            gate.abandon()
            outputFile = nil
            return
        }
        outputFile = nil
        gate.lock.unlock()
    }

    /// A steady clock skew (mic crystal a little slower than the mach clock)
    /// back-fills a handful of frames every few seconds. Logging each one buries
    /// the export in noise, so only fills at or above this duration get a line.
    static let gapFillLogMinSeconds = 0.05

    /// Whether a gap fill of `frames` at `sampleRate` is large enough to log.
    /// Sub-threshold fills are the harmless clock-skew slivers; at or above it
    /// the gap is long enough to be a genuine restart worth one line. Pure so it
    /// can be unit-tested without touching a file or an engine.
    static func shouldLogGapFill(frames: Int, sampleRate: Double) -> Bool {
        Double(frames) >= sampleRate * gapFillLogMinSeconds
    }

    /// Write `frames` zeroed frames to `file` in its processing format, and
    /// return how many it wrote: fewer once `shouldContinue` says stop or a
    /// write throws. `logged: false` leaves the line to a caller that writes
    /// in chunks and logs the total once. Static
    /// (engine-free) so it can be unit-tested directly against an `AVAudioFile`
    /// without any engine setup.
    @discardableResult
    static func writeSilence(
        frames: Int,
        to file: AVAudioFile,
        logged: Bool = true,
        while shouldContinue: () -> Bool = { true },
    ) -> Int {
        // In chunks of at most a second, so a long gap costs one second's
        // buffer rather than one the size of the gap: a stall bridged on
        // revival can be many minutes.
        let chunk = min(frames, max(Int(file.processingFormat.sampleRate), 1))
        guard frames > 0, let silentBuffer = AVAudioPCMBuffer(
            pcmFormat: file.processingFormat,
            frameCapacity: AVAudioFrameCount(chunk),
        ) else { return 0 }
        // AVAudioPCMBuffer storage isn't guaranteed zeroed — clear it.
        if let channel = silentBuffer.floatChannelData?[0] {
            channel.update(repeating: 0, count: chunk)
        }
        var remaining = frames
        do {
            while remaining > 0, shouldContinue() {
                silentBuffer.frameLength = AVAudioFrameCount(min(remaining, chunk))
                try file.write(from: silentBuffer)
                remaining -= Int(silentBuffer.frameLength)
            }
            let written = frames - remaining
            if logged, shouldLogGapFill(frames: written, sampleRate: file.processingFormat.sampleRate) {
                logger.info("Mic: inserted \(written) silent frames to keep the track aligned to wall-clock")
            }
        } catch {
            logger.warning("Mic timeline gap-fill write error: \(error.localizedDescription, privacy: .public)")
        }
        return frames - remaining
    }
}

/// The lock one chunk of a stall's silence bridge is written under, from the
/// check that the attempt is still current to the count of what landed, and
/// which `stop()` takes to close the file. So a stop returns only once the
/// chunk in flight is in the file and the file is closed: the recorder opens
/// the microphone track the moment the stop returns. A lock rather than a
/// `sync` on the restart queue, because that queue can be stuck for good
/// inside a wedged engine start (issue #588), and a stop must never wait on
/// that; the lock is never held across an engine call, only across one
/// chunk's write.
final class TimelineBridgeGate: @unchecked Sendable {
    let lock = NSLock()
    /// Called on the restart queue right before each chunk is written, under
    /// the lock. A no-op in production; a test parks a chunk here to stop the
    /// capture while it is in flight, and sets it before the capture starts.
    var beforeChunk: @Sendable () -> Void = {}
    /// How long `stop()` waits for the chunk in flight; set before the
    /// capture starts. See `closeFileAfterBridgeChunk`.
    var stopWait: TimeInterval = 2
    /// Set by a stop that gave up waiting, and read right before each write,
    /// so no chunk lands in a file the recorder already has. Its own lock,
    /// because the stop sets it without holding `lock`.
    private let abandoned = OSAllocatedUnfairLock(initialState: false)

    var isAbandoned: Bool {
        abandoned.withLock { $0 }
    }

    func abandon() {
        abandoned.withLock { $0 = true }
    }
}
