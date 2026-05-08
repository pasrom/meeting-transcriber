// `@preconcurrency`: ApplicationServices AX globals lack Sendable
// annotations — same gap as Permissions.swift; preemptively guarded.
@preconcurrency import ApplicationServices
import os.log

private let logger = Logger(subsystem: AppPaths.logSubsystem, category: "AXHelper")

/// Shared Accessibility API helpers used by ParticipantReader.
enum AXHelper {
    /// Read a single AX attribute value from an element.
    /// Logs a warning if the call fails with a status other than `noValue`
    /// (which is a normal "attribute is empty" outcome and not a failure).
    static func getAttribute(_ element: AXUIElement, attribute: String) -> AnyObject? {
        var value: AnyObject?
        let err = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        if err != .success && err != .noValue && err != .attributeUnsupported {
            logger.warning(
                "ax_call_failed attribute=\(attribute, privacy: .public) error=\(err.rawValue, privacy: .public)",
            )
        }
        return err == .success ? value : nil
    }
}
