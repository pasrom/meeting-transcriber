import Foundation

/// Which detection strategies auto-watch runs, and how the "Apps to Watch"
/// toggles filter them. Line-cap split out of `WatchingController`; both are
/// static and take their settings as a parameter, so nothing here touches the
/// controller's own state.
@MainActor
extension WatchingController {
    /// The auto-detect detector, filtered by the user's "Apps to Watch" toggles
    /// (`settings.watchApps`). Extracted so the toggle → detection wiring is
    /// unit-testable without spinning up a watch loop.
    static func defaultDetector(settings: AppSettings) -> any MeetingDetecting {
        CompositeMeetingDetector(defaultDetectors(settings: settings))
    }

    /// The strategies `defaultDetector` composes, in priority order. Split out
    /// so the toggle wiring stays assertable: a test can configure one
    /// strategy's injectable providers without reaching into the composite.
    static func defaultDetectors(settings: AppSettings) -> [any MeetingDetecting] {
        let assertions = PowerAssertionDetector(
            patterns: PowerAssertionDetector.patterns(watching: settings.watchApps),
        )
        // Read through the settings each poll rather than captured once, so a
        // Settings "Remove" takes effect without restarting the watch loop.
        assertions.isIdentityDenied = { [settings] app in
            settings.consentDeniedApps.contains(app)
        }
        return [
            assertions,
            MicInputDetector(patterns: MicInputDetector.patterns(watching: settings.watchApps)),
        ]
    }
}
