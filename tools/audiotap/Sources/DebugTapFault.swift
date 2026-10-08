import Foundation

/// Configuration for injecting a microphone fault into `MicCaptureHandler`,
/// used by the e2e lanes that need a fault no runner produces on its own.
///
/// Two faults, each nil when not wanted:
///
/// - a one-shot tap-install fault, for the mic device-change lane (issue
///   #379), which verifies the installTap NSException recovery path;
/// - withheld buffers, for the mic stall lane (issues #724, #706): the engine
///   starts, logs `Mic recording started` and runs, but its buffers are
///   dropped before the handler sees them, so the progress watchdog has to
///   rebuild it and finally release it, as it would a Bluetooth headset that
///   never delivers.
///
/// This is a generic, inert-by-default test seam: production code passes
/// `nil`. Only an e2e build's composition root (`LiveCaptureSession`, gated by
/// `#if E2E_FAULT_INJECTION`) constructs one, so no shipped binary can inject
/// a fault. The type itself and the handler's branches for it are compiled
/// into every build; they are unreachable there, not absent.
public struct DebugTapFault: Sendable {
    /// Delay after the first successful start before the handler self-triggers
    /// one device-change restart whose tap install uses an invalid format.
    public let triggerRestartAfter: TimeInterval?

    /// Seconds after the capture started from which every buffer is dropped,
    /// across every restart and rebuild for the rest of the recording. Zero is
    /// an engine that never delivers; a positive value is one that delivers
    /// and then stops, with no configuration change to say so.
    public let withholdBuffersAfter: TimeInterval?

    public init(triggerRestartAfter: TimeInterval = 2) {
        self.triggerRestartAfter = triggerRestartAfter
        withholdBuffersAfter = nil
    }

    private init(withholdBuffersAfter: TimeInterval) {
        triggerRestartAfter = nil
        self.withholdBuffersAfter = withholdBuffersAfter
    }

    /// An engine that starts and runs but whose buffers stop reaching the
    /// handler `seconds` after the capture started (zero: never reach it).
    public static func withholdingBuffers(after seconds: TimeInterval) -> Self {
        Self(withholdBuffersAfter: seconds)
    }
}
