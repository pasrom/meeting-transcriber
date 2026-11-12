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
        copyAttribute(element, attribute: attribute).value
    }

    /// `getAttribute` with the error kept, for a caller that has to tell a
    /// target that stopped answering (`.cannotComplete`) from an empty value.
    static func copyAttribute(_ element: AXUIElement, attribute: String) -> (value: AnyObject?, error: AXError) {
        var value: AnyObject?
        let err = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        if err != .success && err != .noValue && err != .attributeUnsupported {
            logger.warning(
                "ax_call_failed attribute=\(attribute, privacy: .public) error=\(err.rawValue, privacy: .public)",
            )
        }
        return (err == .success ? value : nil, err)
    }
}
