import AudioTapLib
import Foundation

/// Abstraction for recording, enabling mock injection in tests.
@MainActor
protocol RecordingProvider {
    func start(source: RecordingSource, micDeviceUID: String?, debugLogging: Bool) throws
    func stop() throws -> RecordingResult

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

    var appSignalAges: ChannelSignalAges {
        .deliveringSignalNow
    }

    var micSignalAges: ChannelSignalAges {
        .deliveringSignalNow
    }
}
