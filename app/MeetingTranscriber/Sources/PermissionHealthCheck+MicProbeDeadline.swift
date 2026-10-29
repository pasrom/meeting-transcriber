// The microphone permission probe under a deadline (issue #778).
//
// `probeMicrophone` brings an `AVAudioEngine` up on the input through
// `-[AVAudioEngine inputNode]`, the call that can loop inside AVFAudio and
// never return (issue #588). It runs at launch, on every app activation, on
// the first `/v1/record` and before a manual recording while the startup
// check has not reported. Unbounded, a wedge there parked the awaiting check
// for good. The recording's own first start is bounded for the same wedge
// (`MicCaptureHandler+FirstStart`); this bounds the probe on the same number,
// in the async shape the probe needs.
import AudioTapLib
@preconcurrency import AVFoundation
import Foundation
import os

private let logger = Logger(subsystem: AppPaths.logSubsystem, category: "PermissionHealthCheck")

/// What the live microphone probe learned, as far as it got.
enum MicProbeOutcome: Equatable, Sendable {
    /// The engine came up, or refused to, and the tap was watched for
    /// `PermissionHealthCheck.probeTimeout`: this many buffers arrived. Zero
    /// means the microphone delivered nothing, the evidence `.broken` rests on.
    case answered(bufferCount: Int)
    /// Bringing the engine up did not return within
    /// `PermissionHealthCheck.probeStartDeadline`. Says nothing about the
    /// grant: the call that did not return wedges on a stale default-device
    /// aggregate, not on a permission.
    case didNotAnswer
}

extension PermissionHealthCheck {
    /// How long the probe waits for its engine to come up. The recording's
    /// first microphone start waits this long on the same call; a probe that
    /// waited longer than the start it is meant to clear would only delay the
    /// same answer.
    static let probeStartDeadline = TimeInterval(MicStartLimits.firstStartDeadlineSeconds)

    /// The lane every probe brings its engine up on. Its queue is serial on
    /// purpose: a bring-up that wedges keeps the queue, so the probes after it
    /// report at their deadline without entering the same call, and the process
    /// loses one thread to the wedge instead of one per app activation. On the
    /// cooperative pool, where the probe used to run, each wedge took a pool
    /// thread for good.
    static let probeLane = BringUpLane(label: "com.meetingtranscriber.mic-probe")

    /// The verdict for an authorized microphone once the probe has spoken.
    ///
    /// A probe that did not answer learned nothing, so it changes nothing: the
    /// verdict stays what the last answered probe said, `lastAnswered`. Were it
    /// to report `.healthy` over a known `.broken`, the badge would clear and
    /// the next answer would notify the same problem again. With nothing
    /// answered yet it reports `.healthy`, not `.broken`: `.broken` exists for
    /// one situation, TCC saying yes while the microphone delivers nothing, and
    /// a call that has not returned has said neither. Broken would tell the
    /// user to toggle a grant that is fine, and would refuse a manual recording
    /// (`blocksRecording`) that the recording path can still start under its
    /// own deadline, with a notice that names what it saw.
    static func microphoneVerdict(
        afterAuthorizedProbe outcome: MicProbeOutcome,
        lastAnswered: PermissionStatus?,
    ) -> PermissionStatus {
        switch outcome {
        case let .answered(bufferCount):
            checkMicrophone(authStatus: .authorized, probeSucceeds: micProbeSucceeds(bufferCount: bufferCount))

        case .didNotAnswer:
            lastAnswered ?? .healthy
        }
    }

    /// What the last probe that answered said about an authorized microphone,
    /// for the probes after it that do not. Cleared when TCC stops saying yes,
    /// so a grant toggled off and on starts from no evidence again.
    static let lastAnsweredMicrophoneVerdict = OSAllocatedUnfairLock<PermissionStatus?>(initialState: nil)

    /// Runs `bringUp` on `lane` and hands back what it built, or nil when it
    /// did not return within `deadline`. A return after the deadline goes to
    /// `discardLate` instead, so a late bring-up releases what it built. One
    /// that never returns is never discarded: its thread stays in the call,
    /// as the microphone's restart path accepts.
    ///
    /// While a bring-up that overran its deadline has still not returned, the
    /// lane is wedged and this returns nil at once without enqueuing: queued
    /// behind the wedge, the bring-up could only make its caller wait the full
    /// deadline for an answer already known, and every such block would open
    /// and tear down an engine when the wedged call finally returned.
    static func awaitBringUp<Built: Sendable>(
        deadline: TimeInterval,
        on lane: BringUpLane = probeLane,
        bringUp: @escaping @Sendable () -> Built,
        discardLate: @escaping @Sendable (Built) -> Void,
    ) async -> Built? {
        guard !lane.isWedged else { return nil }
        return await withCheckedContinuation { (continuation: CheckedContinuation<Built?, Never>) in
            let slot = BringUpSlot(continuation, on: lane)
            lane.queue.async {
                let built = bringUp()
                if !slot.resume(with: built) {
                    // The discard tears an engine down on this queue, on the
                    // device that just wedged; the lane stays wedged until
                    // that is over, so no probe is let onto the queue behind it.
                    discardLate(built)
                    lane.lateReturnDiscarded()
                }
            }
            // The deadline fires from neither the lane's queue, which the
            // bring-up may be holding, nor a task on the cooperative pool, which
            // earlier wedges may have drained.
            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + deadline) {
                slot.resumeAtDeadline()
            }
        }
    }

    /// What a bring-up hands back across the deadline.
    private enum ProbeBringUp: Sendable {
        /// The engine runs with a tap that counts buffers.
        case running(ProbeEngine)
        /// The engine could not be brought up; the reason is logged.
        case failed
    }

    /// Unchecked: one side touches an engine, the probe that got it back in
    /// time or the bring-up that returned late and discards it, never both.
    private struct ProbeEngine: @unchecked Sendable {
        let engine: AVAudioEngine
        let inputNode: AVAudioInputNode
        let format: AVAudioFormat
        let counter: BufferCounter

        func teardown() {
            engine.stop()
            inputNode.removeTap(onBus: 0)
        }
    }

    /// Thread-safe mic probe stats (tap callback runs on audio thread).
    private final class BufferCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        private var maxPeak: Float = 0
        func record(buffer: AVAudioPCMBuffer) {
            let peak = PermissionHealthCheck.peakAmplitude(of: buffer)
            lock.lock()
            count += 1
            if peak > maxPeak { maxPeak = peak }
            lock.unlock()
        }

        func snapshot() -> (count: Int, maxPeak: Float) {
            lock.lock(); defer { lock.unlock() }
            return (count, maxPeak)
        }
    }

    static func probeMicrophone() async -> MicProbeOutcome {
        if probeLane.isWedged {
            // One line at info, not the error below: this is the wedge already
            // reported, seen again on the next activation.
            logger.info("Microphone probe: refused, an earlier bring-up still has not returned")
            debugLog("probeMicrophone: refused, lane wedged by an earlier bring-up")
            return .didNotAnswer
        }
        guard let bringUp = await awaitBringUp(
            deadline: probeStartDeadline,
            bringUp: { bringUpProbeEngine() },
            discardLate: { late in
                guard case let .running(probe) = late else { return }
                logger.info("Microphone probe: discarding an engine that came up after the deadline")
                probe.teardown()
            },
        ) else {
            logger.error(
                "Microphone probe: the engine did not come up within \(probeStartDeadline, privacy: .public)s; the probe says nothing about the grant",
            )
            debugLog("probeMicrophone: engine bring-up did not return within \(probeStartDeadline)s")
            return .didNotAnswer
        }
        guard case let .running(probe) = bringUp else { return .answered(bufferCount: 0) }

        let (stats, elapsedMs) = await waitForProbeSignal(
            deadline: Date().addingTimeInterval(probeTimeout),
            pollInterval: Self.probePollInterval,
            snapshot: probe.counter.snapshot,
        )
        probe.teardown()

        // Diagnostic-only (issue #446): buffers flowing but below the noise floor means a
        // likely muted/virtual input — healthy, not broken, but a useful breadcrumb.
        let silentDespiteBuffers = micProbeSucceeds(bufferCount: stats.count)
            && stats.maxPeak <= Self.silentMicPeakThreshold
        debugLog("probeMicrophone: buffers=\(stats.count) peak=\(stats.maxPeak) " +
            "silentDespiteBuffers=\(silentDespiteBuffers) elapsed=\(elapsedMs)ms " +
            "sampleRate=\(probe.format.sampleRate) channels=\(probe.format.channelCount)")
        return .answered(bufferCount: stats.count)
    }

    /// The part of the probe that can wedge: a fresh engine, its input node's
    /// format, a tap, and the start that opens the input. Runs on `probeLane`.
    private static func bringUpProbeEngine() -> ProbeBringUp {
        // No input device available (e.g. Mac Mini server without mic hardware) —
        // accessing AVAudioEngine.inputNode would throw an uncatchable NSException.
        guard AVCaptureDevice.default(for: .audio) != nil else {
            debugLog("probeMicrophone: no input device available")
            return .failed
        }

        let engine = AVAudioEngine()
        let inputNode = engine.inputNode
        // inputFormat reflects what the hardware actually delivers; outputFormat can report
        // a degenerate (sampleRate=0) format when nothing is attached downstream, which
        // would false-fail the guard below.
        let format = inputNode.inputFormat(forBus: 0)

        guard format.sampleRate > 0, format.channelCount > 0 else {
            debugLog("probeMicrophone: invalid format sampleRate=\(format.sampleRate) " +
                "channels=\(format.channelCount)")
            return .failed
        }

        let counter = BufferCounter()
        do {
            // safeInstallTap: a device change mid-probe could make installTap
            // raise an uncatchable NSException (issue #379); treat that as a
            // failed probe rather than an abort.
            try inputNode.safeInstallTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
                if buffer.frameLength > 0 { counter.record(buffer: buffer) }
            }
        } catch {
            debugLog("probeMicrophone: installTap failed: \(error.localizedDescription)")
            return .failed
        }

        do {
            try engine.start()
        } catch {
            inputNode.removeTap(onBus: 0)
            debugLog("probeMicrophone: engine.start() threw: \(error.localizedDescription)")
            return .failed
        }
        return .running(ProbeEngine(engine: engine, inputNode: inputNode, format: format, counter: counter))
    }
}

/// Where probes bring their engines up: one serial queue, and the count of
/// bring-ups on it that overran their deadline and whose late return has not
/// been discarded yet.
final class BringUpLane: Sendable {
    let queue: DispatchQueue
    fileprivate let overrun = OSAllocatedUnfairLock(initialState: 0)

    init(label: String) {
        queue = DispatchQueue(label: label, qos: .userInitiated)
    }

    /// True while a bring-up that outlived its deadline still holds the queue,
    /// in the call or in the discard of what it built.
    var isWedged: Bool {
        overrun.withLock { $0 > 0 }
    }

    fileprivate func lateReturnDiscarded() {
        overrun.withLock { $0 -= 1 }
    }
}

/// Resumes a continuation exactly once, for whichever side gets there first.
/// When the deadline wins it counts the overrun on the lane under its own
/// lock, so the bring-up, which can only see that it lost after that, undoes
/// the count strictly later, once its late return is discarded.
private final class BringUpSlot<Built: Sendable>: Sendable {
    private let continuation: OSAllocatedUnfairLock<CheckedContinuation<Built?, Never>?>
    private let lane: BringUpLane

    init(_ continuation: CheckedContinuation<Built?, Never>, on lane: BringUpLane) {
        self.continuation = OSAllocatedUnfairLock(initialState: continuation)
        self.lane = lane
    }

    /// True when this call resumed the continuation with what the bring-up
    /// built, false when the deadline had already resumed it.
    func resume(with built: Built) -> Bool {
        let taken = continuation.withLock { slot -> CheckedContinuation<Built?, Never>? in
            defer { slot = nil }
            return slot
        }
        guard let taken else { return false }
        taken.resume(returning: built)
        return true
    }

    /// Resumes with nil unless the bring-up already returned.
    func resumeAtDeadline() {
        let taken = continuation.withLock { slot -> CheckedContinuation<Built?, Never>? in
            defer { slot = nil }
            if slot != nil { lane.overrun.withLock { $0 += 1 } }
            return slot
        }
        taken?.resume(returning: nil)
    }
}
