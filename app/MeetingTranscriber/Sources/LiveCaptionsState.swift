import Foundation
import Observation

/// Observable state powering the live caption-bar overlay.
///
/// `LiveTranscriptionController` writes to this on every partial / finalised
/// event from `StreamingTranscriber`. `LiveCaptionsOverlay` observes the
/// fields directly via `@Observable`.
///
/// Reset semantics: `clear()` is called by `LiveTranscriptionController.reset()`
/// at the start of every new recording so the overlay doesn't carry over text
/// from a prior session.
@Observable
@MainActor
final class LiveCaptionsState {
    /// Current hypothesis — refines word-by-word every ~400 ms while speech
    /// is detected. Cleared when a `final` arrives.
    var hypothesis: String = ""

    /// Last few finalised utterances, oldest first. Capped at `maxFinalsKept`.
    private(set) var recentFinals: [String] = []

    /// Timestamp of the last event (partial or final). Drives fade-out on
    /// silence — the overlay can compare against `Date()` to dim or hide.
    private(set) var lastEventAt: Date = .distantPast

    /// Cap on `recentFinals` length. 2 keeps the bar at most two lines of
    /// previous context plus the live hypothesis on a third line.
    static let maxFinalsKept = 2

    func applyPartial(_ text: String) {
        hypothesis = text
        lastEventAt = Date()
    }

    func applyFinalized(_ text: String) {
        hypothesis = ""
        recentFinals.append(text)
        if recentFinals.count > Self.maxFinalsKept {
            recentFinals.removeFirst(recentFinals.count - Self.maxFinalsKept)
        }
        lastEventAt = Date()
    }

    func clear() {
        hypothesis = ""
        recentFinals.removeAll()
        lastEventAt = .distantPast
    }

    /// True when there's anything to show.
    var hasContent: Bool {
        !hypothesis.isEmpty || !recentFinals.isEmpty
    }
}
