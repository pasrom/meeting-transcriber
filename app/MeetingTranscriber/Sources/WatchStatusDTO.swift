import Foundation

/// Wire shape for `GET`/`POST /v1/watch` — the meeting-watching lifecycle as a
/// small, stable projection.
///
/// Deliberately *not* `/state`: that snapshot is the debug surface, a 15-section
/// kitchen sink built for E2E drivers and documented as free to change. A
/// third-party controller (Stream Deck key, Shortcut, shell script) polls this
/// on an interval forever, so it needs a payload that is cheap to fetch and
/// carries a compatibility promise — the same reasoning that split `/v1` out of
/// `/action/*` in the first place.
///
/// `watching` is an explicit boolean rather than something the client infers
/// from a nil `state`: that inference is a semantic subtlety which has no
/// business crossing a public API boundary. `badge` is included because it is
/// the single richest glanceable field — it folds transcribing/diarizing/
/// processing/error/updateAvailable into one value, which is what lets a
/// physical key render more than on/off.
struct WatchStatusDTO: Codable, Equatable {
    /// Whether the watch loop is running *and* not owned by a manual recording.
    let watching: Bool
    /// `WatchLoop.State` raw value (`idle`/`watching`/`recording`/`error`), or
    /// nil when no loop exists.
    let state: String?
    /// `BadgeKind` raw value — what the menu bar icon is showing right now.
    let badge: String
    /// Whether an app-picker recording owns the loop. Watch control is refused
    /// while this is true.
    let manualRecording: Bool
    /// App name awaiting a browser-meeting consent answer, if one is parked.
    let pendingConsentApp: String?
    /// False only when a permission probe has actually failed. A health check
    /// that has not run yet reports true, matching how `BadgeKind.compute`
    /// treats an unknown result — the badge and this field must not disagree.
    let permissionsHealthy: Bool

    /// Fallback for the window between server start and `AppState` being
    /// reachable. Reports "not watching, nothing wrong" rather than failing the
    /// request, so a polling client sees a steady off state instead of an error.
    static let notWatching = Self(
        watching: false,
        state: nil,
        badge: BadgeKind.inactive.rawValue,
        manualRecording: false,
        pendingConsentApp: nil,
        permissionsHealthy: true,
    )
}

/// What a `POST /v1/watch` asks for.
///
/// `start`/`stop` exist alongside `toggle` because a key press expresses a
/// desired outcome, not a delta. A remote controller's view of the app is
/// always slightly stale; if a meeting ended since its last poll, a blind
/// toggle does exactly the wrong thing and stays inverted until someone
/// notices. Idempotent verbs converge instead.
enum WatchAction: String, Codable {
    case start
    case stop
    case toggle
}

/// What a watch-control request actually achieved. Maps 1:1 onto the HTTP
/// status code, so the caller can tell "already on" from "refused" without
/// diffing state before and after.
///
/// Deliberately not `Codable` and not raw-value backed: it never crosses the
/// wire. The route reads it to pick a status code and builds the body from
/// `watchStatusDTO()`. Publishing a wire conformance on a type that has no wire
/// presence would invite a later change to serialise it, quietly promoting
/// these case names into the compatibility promise this file exists to keep.
enum WatchControlOutcome: Equatable {
    /// The request changed the watching state. → 200
    case changed
    /// Already in the requested state; nothing to do. → 200
    case unchanged
    /// Refused: a manual recording owns the loop. → 409
    case blocked
    /// The request was accepted but the state did not settle as asked. → 503
    case failed
}

/// Request body for `POST /v1/watch`. An unrecognised action string fails to
/// decode, which the route turns into a 400 — better than silently treating a
/// typo'd verb as a toggle.
struct WatchActionPayload: Codable, Equatable {
    let action: WatchAction
}
