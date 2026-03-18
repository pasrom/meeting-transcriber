import ApplicationServices

/// Shared Accessibility API helpers used by ParticipantReader.
enum AXHelper {
    /// Read a single AX attribute value from an element.
    static func getAttribute(_ element: AXUIElement, attribute: String) -> AnyObject? {
        var value: AnyObject?
        let err = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        return err == .success ? value : nil
    }
}
