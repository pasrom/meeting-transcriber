import Foundation
import Observation

/// Which capture source a caption came from. Drives the speaker prefix in
/// the overlay ("Du" for the local mic, "Remote" for the meeting app audio).
enum LiveCaptionChannel: Hashable {
    case mic
    case app

    var label: String {
        switch self {
        case .mic: "Du"
        case .app: "Remote"
        }
    }
}

/// A finalised utterance with its source channel attached.
struct LiveCaptionLine: Hashable {
    let channel: LiveCaptionChannel
    let text: String
}

/// Observable state powering the live caption-bar overlay.
///
/// Hypothesis is per-channel because mic and app audio can speak
/// concurrently (you replying to a remote question), and one channel
/// overwriting the other would make the overlay flicker between them.
/// Finalised lines are merged into a single rolling buffer keyed by channel
/// so the overlay renders them in time order with stable speaker prefixes.
///
/// Reset semantics: `clear()` is called by `LiveTranscriptionController.reset()`
/// at the start of every new recording so the overlay doesn't carry over text
/// from a prior session.
@Observable
@MainActor
final class LiveCaptionsState {
    private(set) var hypothesisMic: String = ""
    private(set) var hypothesisApp: String = ""

    /// Last few finalised utterances across both channels, oldest first.
    /// Capped at `maxFinalsKept`.
    private(set) var recentFinals: [LiveCaptionLine] = []

    /// Timestamp of the last event (partial or final). Drives fade-out on
    /// silence — the overlay can compare against `Date()` to dim or hide.
    private(set) var lastEventAt: Date = .distantPast

    /// Cap on `recentFinals` length. 2 keeps the bar at most two prior lines
    /// plus the two live hypothesis rows on top.
    static let maxFinalsKept = 2

    /// Seconds after the last event before the overlay starts fading out.
    static let fadeStartSeconds: TimeInterval = 2.0
    /// Seconds after the last event at which the overlay is fully transparent.
    static let fadeEndSeconds: TimeInterval = 4.0
    /// Seconds after the last event at which content is auto-cleared so the
    /// overlay collapses to nothing (panel itself stays mounted, just empty).
    static let autoClearSeconds: TimeInterval = 5.0

    private var autoClearTask: Task<Void, Never>?

    func applyPartial(_ text: String, channel: LiveCaptionChannel) {
        switch channel {
        case .mic: hypothesisMic = text
        case .app: hypothesisApp = text
        }
        lastEventAt = Date()
        scheduleAutoClear()
    }

    func applyFinalized(_ text: String, channel: LiveCaptionChannel) {
        switch channel {
        case .mic: hypothesisMic = ""
        case .app: hypothesisApp = ""
        }
        recentFinals.append(LiveCaptionLine(channel: channel, text: text))
        if recentFinals.count > Self.maxFinalsKept {
            recentFinals.removeFirst(recentFinals.count - Self.maxFinalsKept)
        }
        lastEventAt = Date()
        scheduleAutoClear()
    }

    func clear() {
        autoClearTask?.cancel()
        autoClearTask = nil
        hypothesisMic = ""
        hypothesisApp = ""
        recentFinals.removeAll()
        lastEventAt = .distantPast
    }

    /// Compute current opacity from a render-time date. Returns 1.0 within
    /// the active window, linearly fades to 0 between `fadeStartSeconds` and
    /// `fadeEndSeconds`, then stays at 0. Pure function so the overlay can
    /// call it from a `TimelineView` body without touching state.
    func opacity(at date: Date) -> Double {
        let elapsed = date.timeIntervalSince(lastEventAt)
        if elapsed < Self.fadeStartSeconds { return 1.0 }
        if elapsed >= Self.fadeEndSeconds { return 0.0 }
        let progress = (elapsed - Self.fadeStartSeconds)
            / (Self.fadeEndSeconds - Self.fadeStartSeconds)
        return max(0.0, 1.0 - progress)
    }

    private func scheduleAutoClear() {
        autoClearTask?.cancel()
        autoClearTask = Task { @MainActor [weak self] in
            let delay = UInt64(Self.autoClearSeconds * 1_000_000_000)
            try? await Task.sleep(nanoseconds: delay)
            guard let self, !Task.isCancelled else { return }
            // Recheck — a newer event may have arrived during sleep.
            if Date().timeIntervalSince(self.lastEventAt) >= Self.autoClearSeconds {
                self.clear()
            }
        }
    }

    /// True when there's anything to show.
    var hasContent: Bool {
        !hypothesisMic.isEmpty
            || !hypothesisApp.isEmpty
            || !recentFinals.isEmpty
    }
}
