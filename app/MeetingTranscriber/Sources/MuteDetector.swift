import ApplicationServices
import Foundation
import os.log

private let logger = Logger(subsystem: AppPaths.logSubsystem, category: "MuteDetector")

/// A point in time where the mute state changed.
struct MuteTransition: Sendable {
    let timestamp: TimeInterval  // ProcessInfo.processInfo.systemUptime
    let isMuted: Bool
}

/// Polls Teams mute state via Accessibility API and records transitions.
///
/// The timeline can later be used to mask mic audio during muted periods.
/// Graceful degradation: if Accessibility is unavailable, records empty timeline.
@Observable
class MuteDetector {
    private(set) var timeline: [MuteTransition] = []
    private(set) var isActive = false
    private let teamsPID: pid_t
    private let pollInterval: TimeInterval
    private var task: Task<Void, Never>?
    private var lastState: Bool?

    /// Override in tests to inject mock mute state.
    var muteStateProvider: ((pid_t) -> Bool?)?

    init(teamsPID: pid_t, pollInterval: TimeInterval = 0.5) {
        self.teamsPID = teamsPID
        self.pollInterval = pollInterval
    }

    func start() {
        guard AXIsProcessTrusted() else {
            logger.warning("Accessibility not granted — mute detection disabled")
            return
        }

        isActive = true
        logger.info("Mute tracker started for PID \(self.teamsPID)")

        task = Task.detached(priority: .utility) { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }

                let state: Bool?
                if let provider = self.muteStateProvider {
                    state = provider(self.teamsPID)
                } else {
                    state = Self.readMuteState(pid: self.teamsPID)
                }

                if let state, state != self.lastState {
                    let transition = MuteTransition(
                        timestamp: ProcessInfo.processInfo.systemUptime,
                        isMuted: state
                    )
                    await MainActor.run {
                        self.timeline.append(transition)
                        self.lastState = state
                    }
                    logger.debug("Mute transition: \(state ? "MUTED" : "UNMUTED")")
                }

                try? await Task.sleep(for: .seconds(self.pollInterval))
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
        isActive = false
        logger.info("Mute tracker stopped — \(self.timeline.count) transitions recorded")
    }

    // MARK: - AX API

    /// Mute-button description prefixes across locales (lowercase).
    /// Teams buttons have descriptions like "Mute (⌘ ⇧ M)" or "Unmute (⌘ ⇧ M)".
    static let mutedPrefixes = ["unmute", "stummschaltung aufheben"]
    static let unmutedPrefixes = ["mute", "stummschalten"]
    static let allPrefixes = mutedPrefixes + unmutedPrefixes

    /// Read the mute state from Teams UI for the given PID.
    /// Returns true if muted, false if unmuted, nil if can't determine.
    static func readMuteState(pid: pid_t) -> Bool? {
        let appElement = AXUIElementCreateApplication(pid)
        guard let button = findMuteButton(appElement) else { return nil }

        for attr in [kAXDescriptionAttribute, kAXTitleAttribute] as [String] {
            guard let text = getAXAttribute(button, attribute: attr) as? String else { continue }
            let lower = text.lowercased()
            if mutedPrefixes.contains(where: { lower.hasPrefix($0) }) {
                return true
            }
            if unmutedPrefixes.contains(where: { lower.hasPrefix($0) }) {
                return false
            }
        }
        return nil
    }

    // MARK: - AX Helpers (delegates to AXHelper)

    static func getAXAttribute(_ element: AXUIElement, attribute: String) -> AnyObject? {
        AXHelper.getAttribute(element, attribute: attribute)
    }

    /// Recursively search AX tree for a button whose description starts
    /// with a mute/unmute label.
    static func findMuteButton(_ element: AXUIElement, depth: Int = 0, maxDepth: Int = 25) -> AXUIElement? {
        if depth > maxDepth { return nil }

        guard let role = getAXAttribute(element, attribute: kAXRoleAttribute) as? String else {
            return nil
        }

        if role == kAXButtonRole as String {
            // Teams buttons use AXDescription
            if let desc = getAXAttribute(element, attribute: kAXDescriptionAttribute) as? String {
                let lower = desc.lowercased()
                if allPrefixes.contains(where: { lower.hasPrefix($0) }) {
                    return element
                }
            }
            // Fallback: AXTitle
            if let title = getAXAttribute(element, attribute: kAXTitleAttribute) as? String {
                let lower = title.lowercased()
                if allPrefixes.contains(where: { lower.hasPrefix($0) }) {
                    return element
                }
            }
        }

        // Recurse into children
        guard let children = getAXAttribute(element, attribute: kAXChildrenAttribute) as? [AXUIElement] else {
            return nil
        }
        for child in children {
            if let found = findMuteButton(child, depth: depth + 1, maxDepth: maxDepth) {
                return found
            }
        }
        return nil
    }
}
