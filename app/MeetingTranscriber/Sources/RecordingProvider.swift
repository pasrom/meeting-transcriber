import AudioTapLib
import Foundation

/// Abstraction for recording, enabling mock injection in tests.
@MainActor
protocol RecordingProvider {
    func start(source: RecordingSource, micDeviceUID: String?, debugLogging: Bool) throws
    func stop() throws -> RecordingResult

    /// `stop()` with the file work (reading the tracks back, mixing, writing
    /// the mix) off the main actor. Ending the capture itself still happens on
    /// the caller's actor. Used where the main thread has to be free while the
    /// mix runs: a quit, whose time budget is a timer on the main actor, and
    /// the mix of a long recording takes seconds. Default: the synchronous
    /// `stop()`, for doubles that have no file work to move.
    func stopOffMain() async throws -> RecordingResult

    /// Instantaneous app-audio level in dBFS. -120 when no capture session is
    /// active or the tap stopped delivering buffers in the last 0.5 s.
    /// Drives the menu-bar asymmetric-silence indicator. Default: -120
    /// (mocks that don't simulate audio levels stay silent).
    var appLevelDBFS: Double { get }

    /// Instantaneous mic level in dBFS, with the same semantics as
    /// `appLevelDBFS`.
    var micLevelDBFS: Double { get }

    /// True once a channel's capture was abandoned for good (issue #588),
    /// whether a restart attempt never returned or the retry budget ran out.
    /// The level alone cannot say this: a channel that fell silent may come
    /// back, one that gave up will not.
    /// Default false so mocks that do not simulate capture failures stay quiet.
    var appCaptureGaveUp: Bool { get }
    var micCaptureGaveUp: Bool { get }

    /// True once the opt-in silent-track watchdog stopped rebuilding the app
    /// capture because its rebuilds did not restore signal (issue #672). Not a
    /// give-up: the channel still captures. Default false.
    var appSilentTrackWatchdogGaveUp: Bool { get }

    /// How long each channel has gone without a buffer, and without one
    /// carrying signal. This is what says whether a channel is broken;
    /// `appLevelDBFS` / `micLevelDBFS` only say how loud it is, and report the
    /// same -120 for a muted device, a dead tap and a channel that was never
    /// opened. Defaults describe a channel delivering normally, so a double
    /// that does not simulate capture never looks broken.
    var appSignalAges: ChannelSignalAges { get }
    var micSignalAges: ChannelSignalAges { get }
}

extension ChannelSignalAges {
    /// A channel that delivered a buffer carrying signal just now. What a
    /// provider reports when it does not simulate capture at all, so a double
    /// has to say explicitly that a channel is broken before it can be
    /// reported as such.
    static let deliveringSignalNow = ChannelSignalAges(secondsSinceLastBuffer: 0, secondsSinceLastEnergy: 0)
}

extension RecordingProvider {
    // Async only to satisfy the requirement: a double has no file work to
    // move, so its stop stays where it is called.
    // swiftlint:disable:next async_without_await
    func stopOffMain() async throws -> RecordingResult {
        try stop()
    }

    var appLevelDBFS: Double {
        -120
    }

    var micLevelDBFS: Double {
        -120
    }

    var appCaptureGaveUp: Bool {
        false
    }

    var micCaptureGaveUp: Bool {
        false
    }

    var appSilentTrackWatchdogGaveUp: Bool {
        false
    }

    var appSignalAges: ChannelSignalAges {
        .deliveringSignalNow
    }

    var micSignalAges: ChannelSignalAges {
        .deliveringSignalNow
    }
}
