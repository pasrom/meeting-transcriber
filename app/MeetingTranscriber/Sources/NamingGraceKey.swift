import Foundation

/// Identity of one "keyboard grace" window in the speaker-naming dialog.
///
/// The grace gate re-locks Confirm and Skip whenever this value changes, so what
/// belongs in it is exactly the set of events after which a keystroke aimed
/// somewhere else can land on the dialog:
///
/// - `revision` — the dialog's data was replaced (first appearance, a Re-run
///   result, or a switch to a different pending job). A fresh UUID per
///   `SpeakerNamingData` instance, so this fires even when the new mapping is
///   byte-identical to the old one.
/// - `pendingJobCount` — another job reached speaker naming. That path posts
///   `.showSpeakerNaming`, which force-activates the app via
///   `NSApp.activate(ignoringOtherApps:)`. When the window is already open on
///   the displayed job, its data does not change, so `revision` alone would
///   leave the buttons live at the exact moment focus is taken from whatever
///   the user was typing in.
///
/// Deliberately *not* included: window key-status. Re-arming whenever the window
/// becomes key would also disable the buttons for someone who clicks into the
/// window and then clicks Confirm, because the gate blocks clicks as well as
/// keystrokes.
struct NamingGraceKey: Hashable {
    let revision: UUID
    let pendingJobCount: Int
}
