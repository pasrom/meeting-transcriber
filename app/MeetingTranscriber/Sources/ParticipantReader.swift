import ApplicationServices
import Foundation
import os.log

private let logger = Logger(subsystem: AppPaths.logSubsystem, category: "ParticipantReader")

/// Reads participant names from Teams meeting roster via Accessibility API
/// and writes them to a JSON file for use during diarization.
enum ParticipantReader {
    /// Known non-name strings in the Teams UI that should be filtered out.
    private static let skipPatterns: Set<String> = [
        "mute", "unmute", "muted", "unmuted", "camera", "share", "chat",
        "people", "raise hand", "leave", "more", "reactions", "participants",
        "in this meeting", "invited", "in the lobby", "presenter", "attendee",
        "organizer", "guest", "(you)", "search", "recording", "transcription",
    ]

    // MARK: - Read Participants

    /// Read participant names from Teams meeting roster via AX API.
    ///
    /// Tries 3 strategies since Teams' AX structure varies between versions:
    /// 1. Look for known panel identifiers (roster-list, people-pane, etc.)
    /// 2. Find AXList/AXTable containers with multiple text rows
    /// 3. Parse window title for "Name1, Name2 | Microsoft Teams" pattern
    ///
    /// Returns nil if roster not found.
    static func readParticipants(pid: pid_t) -> [String]? { // swiftlint:disable:this discouraged_optional_collection
        let appElement = AXUIElementCreateApplication(pid)

        // Strategy 1: Known panel identifiers
        for panelID in ["roster-list", "people-pane", "participant-list", "roster-container"] {
            if let panel = findElementByIdentifier(appElement, identifier: panelID) {
                let texts = extractTextValues(panel)
                let names = filterParticipantNames(texts)
                if !names.isEmpty {
                    logger.info("Found \(names.count) participants via identifier '\(panelID)'")
                    return names
                }
            }
        }

        // Strategy 2: List/Table containers
        for containerRole in ["AXList", "AXTable", "AXOutline"] {
            let containers = findElementsByRole(appElement, role: containerRole)
            for container in containers {
                guard let children = AXHelper.getAttribute(container, attribute: kAXChildrenAttribute) as? [AXUIElement],
                      children.count >= 2 else { continue }

                var rowTexts: [String] = []
                for child in children {
                    let texts = extractTextValues(child, maxDepth: 5)
                    if let first = texts.first {
                        rowTexts.append(first)
                    }
                }
                let names = filterParticipantNames(rowTexts)
                if names.count >= 2 {
                    logger.info("Found \(names.count) participants via \(containerRole) container")
                    return names
                }
            }
        }

        // Strategy 3: Window title parsing
        let windows = findElementsByRole(appElement, role: kAXWindowRole as String, maxDepth: 1)
        for window in windows {
            guard let title = AXHelper.getAttribute(window, attribute: kAXTitleAttribute) as? String else {
                continue
            }
            if title.hasPrefix("Chat |") || title == "Microsoft Teams" { continue }
            if title.contains(" | Microsoft Teams") {
                let meetingPart = title.replacingOccurrences(of: " | Microsoft Teams", with: "")
                if meetingPart.contains(",") {
                    let parts = meetingPart.components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespaces) }
                    let names = filterParticipantNames(parts)
                    if names.count >= 2 {
                        logger.info("Found \(names.count) participants from window title")
                        return names
                    }
                }
            }
        }

        logger.debug("No participant roster found in AX tree")
        return nil
    }

    // MARK: - Filtering

    /// Filter text strings to likely participant names.
    static func filterParticipantNames(_ texts: [String]) -> [String] {
        var names: [String] = []
        var seen: Set<String> = []

        for rawText in texts {
            var text = rawText.trimmingCharacters(in: .whitespaces)
            if text.isEmpty || text.count <= 1 { continue }
            if text.allSatisfy(\.isNumber) { continue }

            let lower = text.lowercased()

            // Skip overly long strings — real names rarely exceed 60 chars
            if text.count > 60 { continue }

            // Skip strings with navigation arrows (screen-shared UI breadcrumbs)
            if text.contains("→") || text.contains("›") { continue }

            // Skip strings ending with ":" — UI labels, not names
            if text.hasSuffix(":") || text.hasSuffix("::") { continue }

            // Skip strings containing URL-like patterns
            if lower.contains("://") || lower.contains(".com") || lower.contains(".ai")
                || lower.contains(".io") || lower.contains(".org") || lower.contains(".net") { continue }

            // Skip strings with path separators (UI navigation, file paths)
            if text.contains("/") && text.count(where: { $0 == "/" }) >= 2 { continue }

            // Skip timestamps like "10:30"
            if text.contains(":") && text.contains(where: \.isNumber) { continue }

            // Skip known UI labels
            if skipPatterns.contains(lower) { continue }
            if skipPatterns.contains(where: { lower.hasPrefix($0) }) { continue }

            // Remove "(you)" suffix
            if lower.hasSuffix("(you)") {
                text = String(text.dropLast(5)).trimmingCharacters(in: .whitespaces)
            }

            if !text.isEmpty && !seen.contains(text) {
                names.append(text)
                seen.insert(text)
            }
        }
        return names
    }

    // MARK: - AX Helpers

    private static func findElementByIdentifier(_ element: AXUIElement, identifier: String, depth: Int = 0, maxDepth: Int = 25) -> AXUIElement? {
        if depth > maxDepth { return nil }

        if let eid = AXHelper.getAttribute(element, attribute: "AXIdentifier") as? String, eid == identifier {
            return element
        }

        guard let children = AXHelper.getAttribute(element, attribute: kAXChildrenAttribute) as? [AXUIElement] else {
            return nil
        }
        for child in children {
            if let found = findElementByIdentifier(child, identifier: identifier, depth: depth + 1, maxDepth: maxDepth) {
                return found
            }
        }
        return nil
    }

    private static func findElementsByRole(_ element: AXUIElement, role: String, depth: Int = 0, maxDepth: Int = 25) -> [AXUIElement] {
        if depth > maxDepth { return [] }

        var results: [AXUIElement] = []

        if let elRole = AXHelper.getAttribute(element, attribute: kAXRoleAttribute) as? String, elRole == role {
            results.append(element)
        }

        if let children = AXHelper.getAttribute(element, attribute: kAXChildrenAttribute) as? [AXUIElement] {
            for child in children {
                results.append(contentsOf: findElementsByRole(child, role: role, depth: depth + 1, maxDepth: maxDepth))
            }
        }
        return results
    }

    private static func extractTextValues(_ element: AXUIElement, depth: Int = 0, maxDepth: Int = 10) -> [String] {
        if depth > maxDepth { return [] }

        var texts: [String] = []

        if let role = AXHelper.getAttribute(element, attribute: kAXRoleAttribute) as? String,
           role == kAXStaticTextRole as String {
            for attr in [kAXValueAttribute, kAXTitleAttribute] as [String] {
                if let val = AXHelper.getAttribute(element, attribute: attr) as? String {
                    let trimmed = val.trimmingCharacters(in: .whitespaces)
                    if !trimmed.isEmpty { texts.append(trimmed) }
                }
            }
        }

        if let children = AXHelper.getAttribute(element, attribute: kAXChildrenAttribute) as? [AXUIElement] {
            for child in children {
                texts.append(contentsOf: extractTextValues(child, depth: depth + 1, maxDepth: maxDepth))
            }
        }
        return texts
    }
}
