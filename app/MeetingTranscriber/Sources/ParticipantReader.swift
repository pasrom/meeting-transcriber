import ApplicationServices
import Foundation
import os.log

private let logger = Logger(subsystem: AppPaths.logSubsystem, category: "ParticipantReader")

/// Reads participant names from the Teams meeting roster via the
/// Accessibility API, once at recording start. The names travel with the
/// recording (pipeline job or record-only sidecar) and are offered as
/// suggestions when naming speakers.
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
    /// Returns nil if roster not found, and without walking the tree at all
    /// when the app is not trusted for Accessibility: every AX call would
    /// fail and log a warning of its own. Nor in a build that does not use the
    /// grant (`PermissionHealthCheck.accessibilityApplies`), even if the process
    /// happens to be trusted: that build reports Accessibility as not
    /// applicable and has no Settings row, so a read there would run with no
    /// way to diagnose it. `accessibilityApplies`, `isTrusted` and `makeRoot`
    /// are seams for tests, so they do not depend on this build or this
    /// machine's grant.
    static func readParticipants(
        pid: pid_t,
        accessibilityApplies: Bool = PermissionHealthCheck.accessibilityApplies,
        isTrusted: () -> Bool = { AXIsProcessTrusted() },
        makeRoot: (pid_t) -> AXUIElement = AXUIElementCreateApplication,
        access: RosterAccess = .live,
    ) -> [String]? { // swiftlint:disable:this discouraged_optional_collection
        guard accessibilityApplies else { return nil }
        guard isTrusted() else {
            logger.info("Accessibility not granted, skipping the Teams participant roster")
            return nil
        }
        return readRoster(makeRoot(pid), walk: RosterWalk(access: access))
    }

    // MARK: - Bounds

    /// How long a single AX call into Teams may block before it gives up.
    static let callTimeout: Float = 1
    /// How long one whole roster read may take.
    static let readBudget: TimeInterval = 2

    /// The AX calls one roster read makes, and its clock. A seam for tests,
    /// so the bounds can be checked against a fake tree.
    struct RosterAccess {
        var copyAttribute: (AXUIElement, String) -> (value: AnyObject?, error: AXError)
        var setTimeout: (AXUIElement, Float) -> Void
        var now: () -> TimeInterval

        static var live: Self {
            Self(
                copyAttribute: { AXHelper.copyAttribute($0, attribute: $1) },
                setTimeout: { _ = AXUIElementSetMessagingTimeout($0, $1) },
                now: { ProcessInfo.processInfo.systemUptime },
            )
        }
    }

    /// One roster read: every attribute read of every walk goes through here,
    /// and once the read is over each further one answers nil without a call,
    /// so the walks still to come unwind at once.
    ///
    /// The read runs on the main actor, and each AX call is a synchronous
    /// message to Teams that, left alone, blocks for the system's messaging
    /// timeout, seconds rather than milliseconds, when Teams does not answer.
    /// Unbounded, a hung Teams cost about sixteen of those, one per walk
    /// entry, and a large tree thousands of calls per walk, with the menu bar
    /// frozen meanwhile. The names are only suggestions, so giving up early
    /// costs little. The timeout is set per element because one set on an
    /// element does not carry over to the elements read from it, and not
    /// process-wide, which would also shorten the app's other AX calls.
    private final class RosterWalk {
        private let access: RosterAccess
        private let deadline: TimeInterval
        /// True once the read was cut short. What a walk gathered up to then
        /// is a part of the tree, not the roster.
        private(set) var over = false

        init(access: RosterAccess) {
            self.access = access
            deadline = access.now() + ParticipantReader.readBudget
        }

        func attribute(_ element: AXUIElement, _ name: String) -> AnyObject? {
            guard !over else { return nil }
            guard access.now() < deadline else {
                logger.info("Teams participant roster read ran out of time, giving up")
                over = true
                return nil
            }
            access.setTimeout(element, ParticipantReader.callTimeout)
            let (value, error) = access.copyAttribute(element, name)
            if error == .cannotComplete {
                logger.info("Teams did not answer an accessibility call, giving up on the participant roster")
                over = true
            }
            return value
        }
    }

    /// Tries 3 strategies since Teams' AX structure varies between versions:
    /// 1. Look for known panel identifiers (roster-list, people-pane, etc.)
    /// 2. Find AXList/AXTable containers with multiple text rows
    /// 3. Parse window title for "Name1, Name2 | Microsoft Teams" pattern
    ///
    /// The title is the last choice but is read first: it costs a handful of
    /// calls, while 1 and 2 walk the whole tree and, with the roster panel
    /// closed, find nothing. On a large tree they would spend the read's
    /// budget doing so and leave none for the title. A roster the read was cut
    /// off in is dropped for the same reason: its first rows are not everyone.
    private static func readRoster(_ appElement: AXUIElement, walk: RosterWalk) -> [String]? { // swiftlint:disable:this discouraged_optional_collection
        let titleNames = windowTitleNames(appElement, walk: walk)

        // Strategy 1: Known panel identifiers
        for panelID in ["roster-list", "people-pane", "participant-list", "roster-container"] {
            if let panel = findElementByIdentifier(appElement, identifier: panelID, walk: walk) {
                let texts = extractTextValues(panel, walk: walk)
                let names = filterParticipantNames(texts)
                if !names.isEmpty, !walk.over {
                    logger.info("Found \(names.count) participants via identifier '\(panelID)'")
                    return names
                }
            }
        }

        // Strategy 2: List/Table containers
        for containerRole in ["AXList", "AXTable", "AXOutline"] {
            let containers = findElementsByRole(appElement, role: containerRole, walk: walk)
            for container in containers {
                guard let children = walk.attribute(container, kAXChildrenAttribute) as? [AXUIElement],
                      children.count >= 2 else { continue }

                var rowTexts: [String] = []
                for child in children {
                    let texts = extractTextValues(child, walk: walk, maxDepth: 5)
                    if let first = texts.first {
                        rowTexts.append(first)
                    }
                }
                let names = filterParticipantNames(rowTexts)
                if names.count >= 2, !walk.over {
                    logger.info("Found \(names.count) participants via \(containerRole) container")
                    return names
                }
            }
        }

        if let titleNames {
            logger.info("Found \(titleNames.count) participants from window title")
            return titleNames
        }
        logger.debug("No participant roster found in AX tree")
        return nil
    }

    /// Strategy 3: names from a "Name1, Name2 | Microsoft Teams" window title.
    private static func windowTitleNames(_ appElement: AXUIElement, walk: RosterWalk) -> [String]? { // swiftlint:disable:this discouraged_optional_collection
        let windows = findElementsByRole(appElement, role: kAXWindowRole as String, walk: walk, maxDepth: 1)
        for window in windows {
            guard let title = walk.attribute(window, kAXTitleAttribute) as? String else {
                continue
            }
            if title.hasPrefix("Chat |") || title == "Microsoft Teams" { continue }
            if title.contains(" | Microsoft Teams") {
                let meetingPart = title.replacingOccurrences(of: " | Microsoft Teams", with: "")
                if meetingPart.contains(",") {
                    let parts = meetingPart.components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespaces) }
                    let names = filterParticipantNames(parts)
                    if names.count >= 2 { return names }
                }
            }
        }
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
            if skipPatterns.contains(where: { startsWithWord($0, in: lower) }) { continue }

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

    /// Whether `text` starts with `word` as a whole word, its plural
    /// included: "share screen" and "presenters" are labels, "sharelle" is a
    /// name.
    private static func startsWithWord(_ word: String, in text: String) -> Bool {
        guard text.hasPrefix(word) else { return false }
        var rest = text.dropFirst(word.count)
        if rest.first == "s" { rest = rest.dropFirst() }
        return rest.first.map { !$0.isLetter } ?? true
    }

    // MARK: - AX Helpers

    private static func findElementByIdentifier(
        _ element: AXUIElement, identifier: String, walk: RosterWalk, depth: Int = 0, maxDepth: Int = 25,
    ) -> AXUIElement? {
        if depth > maxDepth { return nil }

        if let eid = walk.attribute(element, "AXIdentifier") as? String, eid == identifier {
            return element
        }

        guard let children = walk.attribute(element, kAXChildrenAttribute) as? [AXUIElement] else {
            return nil
        }
        for child in children {
            if let found = findElementByIdentifier(child, identifier: identifier, walk: walk, depth: depth + 1, maxDepth: maxDepth) {
                return found
            }
        }
        return nil
    }

    private static func findElementsByRole(
        _ element: AXUIElement, role: String, walk: RosterWalk, depth: Int = 0, maxDepth: Int = 25,
    ) -> [AXUIElement] {
        if depth > maxDepth { return [] }

        var results: [AXUIElement] = []

        if let elRole = walk.attribute(element, kAXRoleAttribute) as? String, elRole == role {
            results.append(element)
        }

        if let children = walk.attribute(element, kAXChildrenAttribute) as? [AXUIElement] {
            for child in children {
                results.append(contentsOf: findElementsByRole(child, role: role, walk: walk, depth: depth + 1, maxDepth: maxDepth))
            }
        }
        return results
    }

    private static func extractTextValues(_ element: AXUIElement, walk: RosterWalk, depth: Int = 0, maxDepth: Int = 10) -> [String] {
        if depth > maxDepth { return [] }

        var texts: [String] = []

        if let role = walk.attribute(element, kAXRoleAttribute) as? String,
           role == kAXStaticTextRole as String {
            for attr in [kAXValueAttribute, kAXTitleAttribute] as [String] {
                if let val = walk.attribute(element, attr) as? String {
                    let trimmed = val.trimmingCharacters(in: .whitespaces)
                    if !trimmed.isEmpty { texts.append(trimmed) }
                }
            }
        }

        if let children = walk.attribute(element, kAXChildrenAttribute) as? [AXUIElement] {
            for child in children {
                texts.append(contentsOf: extractTextValues(child, walk: walk, depth: depth + 1, maxDepth: maxDepth))
            }
        }
        return texts
    }
}
