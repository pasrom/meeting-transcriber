@preconcurrency import AVFoundation
import Foundation
import os.log

private let logger = Logger(subsystem: "com.meetingtranscriber.audiotap", category: "MicCapture")

/// Debug fault injection for the e2e lanes (issues #379, #724/#706), split from
/// `MicCaptureHandler.swift` to keep that file under the line cap. Inert unless
/// a `DebugTapFault` was injected; see that type for which build can inject one.
extension MicCaptureHandler {
    /// No-op in production. Under a withheld-buffers fault, notes when the
    /// capture started so the tap block can tell when to start dropping.
    func noteDebugFaultStart() {
        guard let after = debugFault?.withholdBuffersAfter else { return }
        debugFaultStartedAt = clock()
        logger.warning(
            "[debug-fault] withholding every mic buffer from \(after, privacy: .public)s after the start (issues #724/#706 repro)",
        )
    }

    /// Always false in production. Under a withheld-buffers fault, true for
    /// every buffer from the configured point on, whichever engine delivered
    /// it: the fault has to outlive the watchdog's rebuilds, or the first one
    /// would cure it. Checked before the buffer is published, so to the
    /// watchdog and to the file it never arrived.
    func debugFaultWithholdsBuffer() -> Bool {
        guard let after = debugFault?.withholdBuffersAfter else { return false }
        return clock() - debugFaultStartedAt >= after
    }

    /// In production (`debugFault == nil`) returns `real` unchanged. Under an
    /// injected fault it returns an invalid (0 Hz) tap format exactly once —
    /// the condition that makes installTapOnBus raise
    /// `IsFormatSampleRateAndChannelCountValid` — so the e2e can verify the
    /// NSException recovery path end-to-end.
    func resolveTapInstallFormat(default real: AVAudioFormat) -> AVAudioFormat {
        guard injectBadTapFormatOnce else { return real }
        injectBadTapFormatOnce = false
        guard let bad = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: 0, channels: 1, interleaved: false,
        ) else { return real }
        logger.warning("[debug-fault] installing invalid (0 Hz) tap format (issue #379 repro)")
        return bad
    }

    /// No-op in production. When a `DebugTapFault` was injected: once, after the
    /// first successful start, schedule a single self-triggered device-change
    /// restart whose tap install uses the bad format. Drives the real
    /// handleDeviceChange -> launchRestartAttempt -> startEngine path so the
    /// reproduction exercises production code, not a shortcut.
    func armDebugFaultIfNeeded() {
        guard let triggerRestartAfter = debugFault?.triggerRestartAfter, !debugFaultArmed else { return }
        debugFaultArmed = true
        DispatchQueue.main.asyncAfter(deadline: .now() + triggerRestartAfter) { [weak self] in
            guard let self, self.isRecording else { return }
            logger.warning("[debug-fault] firing simulated mic device-change mid-recording (issue #379 repro)")
            self.injectBadTapFormatOnce = true
            self.handleDeviceChange()
        }
    }
}
