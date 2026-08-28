import AudioTapLib
@testable import MeetingTranscriber
import XCTest

/// Shared setup for the two suites that drive `ChannelHealthController` through
/// its `applyTick` seam: the tint episodes in `ChannelHealthIntegrationTests`
/// and the capture faults in `ChannelFaultIntegrationTests`. Split because one
/// class covering both grew past the file-length limit, and because the two
/// answer genuinely different questions about the same controller.
@MainActor
enum ChannelHealthHarness {
    /// A channel whose buffers stopped arriving: the tap died, the device was
    /// unplugged, the permission went away.
    static let stoppedDelivering = ChannelSignalAges(secondsSinceLastBuffer: 600, secondsSinceLastEnergy: 600)

    /// A channel still delivering buffers, every sample in them zero: muted by
    /// the device or by macOS, as opposed to merely quiet.
    static let deliveringSilence = ChannelSignalAges(secondsSinceLastBuffer: 0, secondsSinceLastEnergy: 600)

    /// A bare controller (not a full `AppState`), settings-backed closures and a
    /// notifier spy. The debounce is pinned to 30 s, the minimum the production
    /// clamp allows, and every test times relative to it.
    static func make() -> (ChannelHealthController, MockRecorder, RecordingNotifier, AppSettings) {
        let suite = "ChannelHealthHarness-\(getpid())-\(UUID().uuidString)"
        // swiftlint:disable:next force_unwrapping
        let defaults = UserDefaults(suiteName: suite)!
        let settings = AppSettings(defaults: defaults)
        settings.perChannelIndicatorEnabled = true
        settings.asymmetricSilenceWarningSeconds = 30

        let notifier = RecordingNotifier()
        let controller = ChannelHealthController(
            notifier: notifier,
            debounceSeconds: { settings.asymmetricSilenceWarningSeconds },
            indicatorEnabled: { settings.perChannelIndicatorEnabled },
        )
        return (controller, MockRecorder(), notifier, settings)
    }
}
