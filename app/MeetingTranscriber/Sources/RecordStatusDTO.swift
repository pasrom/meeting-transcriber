import Foundation

/// Wire shape for `GET`/`POST /v1/record` — the microphone-recording lifecycle
/// as a small, stable projection, built alongside `WatchStatusDTO` and for the
/// same audience: a Stream Deck key, a Shortcut, a shell script.
///
/// A resource of its own rather than a verb on `/v1/watch`, because the two
/// answer different questions and refuse for different reasons. Watching arms
/// the detector and records nothing by itself, so it starts on a machine whose
/// microphone is switched off or denied; this one records the room right now,
/// where either of those means capturing nothing at all.
///
/// The fields are facts, not advice. A client decides what to draw from them:
/// `recording` for the key itself, and `otherRecordingActive` / `noMic` /
/// `microphoneHealthy` to explain a refusal it just received — or to grey the
/// key out before pressing.
struct RecordStatusDTO: Codable, Equatable {
    /// Whether a microphone-only recording is in progress.
    ///
    /// Deliberately narrower than "something is recording": an app-picker
    /// recording and an auto-detected meeting are not this endpoint's recording,
    /// and reporting them here would invite a client to `stop` one it never
    /// started. `otherRecordingActive` carries those.
    let recording: Bool
    /// Whether a start has been accepted but is not recording yet.
    ///
    /// A start can sit for a while: it waits on the microphone permission gate,
    /// and on a first run that means an OS dialog nobody has answered. Without
    /// this field the whole window reads as plain idle, so a key that renders
    /// "press to start" from `recording` keeps offering a press that will only
    /// queue behind the one already waiting. `WatchStatusDTO.manualRecording`
    /// covers the same window on the other resource.
    let startPending: Bool
    /// `WatchLoop.State` raw value (`idle`/`watching`/`recording`/`error`), or
    /// nil when no loop exists.
    let state: String?
    /// `BadgeKind` raw value — what the menu bar icon is showing right now.
    let badge: String
    /// Whether some other capture owns the watch loop: an auto-detected meeting
    /// or an app-picker recording. A start is refused with 409 while this is
    /// true, because it would clobber a recording already in progress.
    let otherRecordingActive: Bool
    /// Whether the user set "No Microphone (app audio only)". A start is refused
    /// with 412 while it is: honouring the setting here would record nothing,
    /// and overriding it would put on tape the one thing the setting exists to
    /// keep off it.
    let noMic: Bool
    /// False only when a microphone probe has actually failed — denied, or
    /// allowed-but-not-working. A check that has not run yet reports true, the
    /// same way `WatchStatusDTO.permissionsHealthy` treats an unknown result.
    ///
    /// Scoped to the one permission a microphone recording needs, not the
    /// aggregate: a denied Screen Recording grant is irrelevant here (nothing
    /// taps a process), and reporting it would describe this endpoint as broken
    /// on exactly the machines where it is the capture path that still works.
    let microphoneHealthy: Bool

    /// Fallback for the window between server start and `AppState` being
    /// reachable. Reports "not recording, nothing in the way" rather than
    /// failing the request, so a client polling on an interval never has to
    /// special-case launch.
    static let notRecording = Self(
        recording: false,
        startPending: false,
        state: nil,
        badge: BadgeKind.inactive.rawValue,
        otherRecordingActive: false,
        noMic: false,
        microphoneHealthy: true,
    )
}

/// What a `POST /v1/record` asks for. `start`/`stop` sit alongside `toggle` for
/// the reason spelled out on `WatchAction`.
///
/// A separate enum from that one, rather than a shared verb set, so a verb added
/// to one resource does not silently appear on the other's payload.
enum RecordAction: String, Codable {
    case start
    case stop
    case toggle
}

/// What a record-control request actually achieved. Maps 1:1 onto the HTTP
/// status code, so a caller can tell "already recording" from "refused" without
/// diffing state before and after.
///
/// Deliberately not `Codable`, for the same reason as `WatchControlOutcome`: it
/// never crosses the wire. The route reads it to pick a status code and builds
/// the body from `recordStatusDTO()`.
///
/// One case more than `WatchControlOutcome`, and that case is why this endpoint
/// exists as its own resource: a microphone recording has preconditions that
/// watching does not, and both of them mean nothing would be captured.
enum RecordControlOutcome: Equatable {
    /// The request changed the recording state. → 200
    case changed
    /// Already in the requested state; nothing to do. → 200
    case unchanged
    /// Refused: another recording owns the loop and starting would clobber it. → 409
    case blocked
    /// Refused on a precondition the caller has to fix first — "No Microphone"
    /// is set, or the microphone permission is denied or broken. → 412
    ///
    /// Distinct from `.failed` because retrying changes nothing: the answer is
    /// stable until someone flips a switch, in Settings or in System Settings.
    case refused
    /// The request was accepted but the state did not settle as asked. → 503
    case failed
}

/// Request body for `POST /v1/record`. An unrecognised action string fails to
/// decode, which the route turns into a 400 — better than silently treating a
/// typo'd verb as a toggle.
struct RecordActionPayload: Codable, Equatable {
    let action: RecordAction
}
