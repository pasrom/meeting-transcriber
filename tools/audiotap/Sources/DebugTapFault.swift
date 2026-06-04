import Foundation

/// Configuration for injecting a one-shot tap-install fault into
/// `MicCaptureHandler`, used by the mic device-change e2e (issue #379) to
/// verify the installTap NSException recovery path end-to-end.
///
/// This is a generic, inert-by-default test seam: production code passes
/// `nil`. Only an e2e build's composition root (DualSourceRecorder, gated by
/// `#if E2E_FAULT_INJECTION`) constructs one, so the fault capability is
/// physically absent from every shipped binary.
public struct DebugTapFault: Sendable {
    /// Delay after the first successful start before the handler self-triggers
    /// one device-change restart whose tap install uses an invalid format.
    public let triggerRestartAfter: TimeInterval

    public init(triggerRestartAfter: TimeInterval = 2) {
        self.triggerRestartAfter = triggerRestartAfter
    }
}
