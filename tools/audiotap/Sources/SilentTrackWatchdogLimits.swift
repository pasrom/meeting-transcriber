import Foundation

/// The silent-track watchdog's limits that user-facing copy names (issue
/// #672). Public so the app's help text and notification interpolate the
/// values the policy enforces rather than restating them, which is how copy
/// and behaviour drift apart. `SilentTrackWatchdogPolicy` reads its own
/// constants from here; its doc comment says why each value is what it is.
public enum SilentTrackWatchdogLimits {
    /// Seconds between two checks, and so between two rebuilds.
    public static let secondsBetweenRebuilds: TimeInterval = 60
    /// Rebuilds in one zero run that did not bring audio back before the
    /// watchdog stops and tells the user.
    public static let rebuildsWithoutSignal = 3
    /// Rebuilds per recording, however often the budget refills.
    public static let rebuildsPerRecording = 6
}
