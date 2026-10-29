@testable import AudioTapLib
@preconcurrency import AVFoundation
import XCTest

/// Whether an engine configuration change has to restart the microphone
/// (issues #706, #724). The field shape is described on the policy.
final class MicConfigurationChangePolicyTests: XCTestCase {
    private typealias Policy = MicConfigurationChangePolicy

    private let builtIn = MicEngineConfiguration(deviceID: 115, sampleRate: 48000, channelCount: 1)

    /// The self-inflicted change: the unit is still on the pinned device, in
    /// the format the tap was installed for, and the engine is running.
    /// Restarting there is what fed the loop.
    func testAChangeThatLeftThePinnedEngineAsItStartedIsIgnored() {
        let reading = MicConfigurationChangeReading(atStart: builtIn, now: builtIn, isRunning: true)
        XCTAssertEqual(Policy.decide(reading), .ignore)
    }

    /// No reading, because nothing was pinned, the pin did not take or the
    /// unit could not be read, is no evidence that nothing changed.
    func testNoReadingRestarts() {
        XCTAssertEqual(Policy.decide(nil), .restart)
    }

    /// An engine that stopped on the change needs a new one, however
    /// unchanged the rest looks.
    func testAStoppedEngineRestarts() {
        let reading = MicConfigurationChangeReading(atStart: builtIn, now: builtIn, isRunning: false)
        XCTAssertEqual(Policy.decide(reading), .restart)
    }

    /// The unit left the pinned device: the device went away or something
    /// moved it.
    func testAUnitOnAnotherDeviceRestarts() {
        var moved = builtIn
        moved.deviceID = 90
        let reading = MicConfigurationChangeReading(atStart: builtIn, now: moved, isRunning: true)
        XCTAssertEqual(Policy.decide(reading), .restart)
    }

    /// A rate change, a headset dropping into its call profile, leaves a tap
    /// that no longer matches the node.
    func testANewSampleRateRestarts() {
        var resampled = builtIn
        resampled.sampleRate = 24000
        let reading = MicConfigurationChangeReading(atStart: builtIn, now: resampled, isRunning: true)
        XCTAssertEqual(Policy.decide(reading), .restart)
    }

    /// Another app's voice processing turning the built-in microphone into a
    /// multi-channel array mid-call changes the channel count, not the rate.
    func testANewChannelCountRestarts() {
        var array = builtIn
        array.channelCount = 3
        let reading = MicConfigurationChangeReading(atStart: builtIn, now: array, isRunning: true)
        XCTAssertEqual(Policy.decide(reading), .restart)
    }

    /// An unplugged pinned device the unit still reports: the configured UID
    /// no longer resolves to it, so the restart falls back to the default.
    func testAPinnedDeviceThatIsGoneRestarts() {
        let reading = MicConfigurationChangeReading(
            atStart: builtIn, now: builtIn, isRunning: true, pinnedDevicePresent: false,
        )
        XCTAssertEqual(Policy.decide(reading), .restart)
    }

    /// Same rate and channels, but the sample layout moved under the tap.
    func testANewSampleFormatRestarts() {
        var interleaved = builtIn
        interleaved.formatFlags = kAudioFormatFlagsNativeFloatPacked
        let reading = MicConfigurationChangeReading(atStart: builtIn, now: interleaved, isRunning: true)
        XCTAssertEqual(Policy.decide(reading), .restart)
    }

    /// Only a pin the unit confirmed puts an engine under the policy: a
    /// refused, unadopted or unreadable set leaves the unit where the policy
    /// cannot vouch for it.
    func testOnlyAnAdoptedPinIsConfirmed() {
        let uid = "BuiltInMicrophoneDevice"
        XCTAssertTrue(MicDevicePinOutcome.set(uid: uid, requested: 42, status: noErr, actual: 42).isConfirmed)
        XCTAssertFalse(MicDevicePinOutcome.set(uid: uid, requested: 42, status: -50, actual: 42).isConfirmed)
        XCTAssertFalse(MicDevicePinOutcome.set(uid: uid, requested: 42, status: noErr, actual: 7).isConfirmed)
        XCTAssertFalse(MicDevicePinOutcome.set(uid: uid, requested: 42, status: noErr, actual: nil).isConfirmed)
        XCTAssertFalse(MicDevicePinOutcome.notRequested.isConfirmed)
        XCTAssertFalse(MicDevicePinOutcome.unresolvedUID(uid).isConfirmed)
    }
}
