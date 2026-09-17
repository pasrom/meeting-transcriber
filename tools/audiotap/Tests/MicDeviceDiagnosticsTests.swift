@testable import AudioTapLib
import AudioToolbox
import CoreAudio
import XCTest

/// The microphone diagnostics have to answer one question truthfully: which
/// microphone is this recording actually coming from. Two defects meant they
/// could not (issue #724), and both were silent, so a field report that
/// configured one device and logged another could not be resolved either way.
///
/// This pins the half that is decidable without audio hardware: what a pin
/// attempt concluded, how loudly it says so, and what the resulting line reads
/// like. That the handler sources the device from the session rather than from
/// the system default is pinned in `MicEngineSessionSeamTests`, because only
/// the handler can be driven without a real engine.
final class MicDeviceDiagnosticsTests: XCTestCase {
    private let builtIn = "BuiltInMicrophoneDevice"

    // MARK: - What a pin attempt concluded

    func testNothingRequestedConcludesNothing() {
        let outcome = MicDevicePinOutcome.notRequested

        XCTAssertNil(outcome.logLine, "nothing was asked for, so there is nothing to report")
        XCTAssertEqual(outcome.level, .info)
    }

    func testAnAdoptedPinIsOrdinary() {
        let outcome = MicDevicePinOutcome.set(
            uid: builtIn, requested: 42, status: noErr, actual: 42,
        )

        XCTAssertEqual(outcome.level, .info)
        XCTAssertEqual(outcome.logLine, "Mic device set: the configured microphone (ID 42)")
    }

    /// The first defect. `AudioUnitSetProperty`'s status was discarded and the
    /// success line logged unconditionally, so a refused pin was
    /// indistinguishable from an accepted one while the recording ran on a
    /// microphone the user had not chosen.
    func testARefusedSetIsAnErrorAndSaysSoDifferently() throws {
        let refused = MicDevicePinOutcome.set(
            uid: builtIn, requested: 42, status: kAudioUnitErr_InvalidPropertyValue, actual: 104,
        )
        let adopted = MicDevicePinOutcome.set(
            uid: builtIn, requested: 42, status: noErr, actual: 42,
        )

        XCTAssertEqual(refused.level, .error)

        let line = try XCTUnwrap(refused.logLine)
        XCTAssertNotEqual(line, adopted.logLine, "a refused set must not read like an accepted one")
        XCTAssertTrue(
            line.contains("\(kAudioUnitErr_InvalidPropertyValue)"),
            "the status is the only thing telling the refusals apart: \(line)",
        )
    }

    /// Measured on hardware, which is why the status is checked at all: a bogus
    /// device id comes back as `kAudioUnitErr_InvalidPropertyValue` (-10851).
    func testAnyNonZeroStatusIsAnError() {
        for status in [OSStatus(-1), kAudioUnitErr_InvalidPropertyValue, kAudioUnitErr_Uninitialized, 1] {
            let outcome = MicDevicePinOutcome.set(
                uid: builtIn, requested: 42, status: status, actual: 42,
            )
            XCTAssertEqual(outcome.level, .error, "status \(status) must not read as success")
        }
    }

    /// `noErr` says the call was accepted, not that the unit moved. Without the
    /// read-back this case is invisible, and it is the one where the log would
    /// still be claiming the configured microphone.
    func testAnAcceptedButUnadoptedPinIsAnError() throws {
        let outcome = MicDevicePinOutcome.set(
            uid: builtIn, requested: 42, status: noErr, actual: 104,
        )

        XCTAssertEqual(outcome.level, .error)

        let line = try XCTUnwrap(outcome.logLine)
        XCTAssertTrue(line.contains("ID 104"), "the line must name where the unit actually is: \(line)")
    }

    /// An unanswerable read-back is not evidence of anything, so it must not be
    /// reported like a contradicted one. The set was accepted; all that is
    /// missing is the confirmation, and the line says exactly that.
    func testAnUnconfirmedPinIsNeitherSuccessNorFailure() throws {
        let outcome = MicDevicePinOutcome.set(
            uid: builtIn, requested: 42, status: noErr, actual: nil,
        )

        XCTAssertEqual(outcome.level, .default, "not an error: nothing contradicted the set")

        let line = try XCTUnwrap(outcome.logLine)
        XCTAssertTrue(line.contains("could not be asked to confirm"), line)
        XCTAssertFalse(
            line.contains("not on the configured microphone"),
            "an unread confirmation must not be stated as a known wrong device: \(line)",
        )
    }

    /// A configured device that is simply absent is ordinary, so it must not
    /// arrive at error level: a headset asleep would otherwise log an error on
    /// every recording and bury the refusals above in the same filter.
    func testAnAbsentConfiguredDeviceIsNotAnError() {
        let outcome = MicDevicePinOutcome.unresolvedUID("GoneWithTheHeadset")

        XCTAssertEqual(outcome.level, .default, "absent is ordinary, refused is not")
        XCTAssertNotNil(outcome.logLine)
    }

    /// The line is unconditional and lands in the exported diagnostics, which
    /// Settings offers as redacted. os_log's own redaction is that promise, so
    /// a device UID must not travel in a line the code marks public: an audio
    /// UID is stable across boots and a USB one carries the serial.
    func testNoLineCarriesTheDeviceUID() {
        let secret = "AppleUSBAudioEngine:Vendor:Product:SERIAL1234:1"
        let outcomes: [MicDevicePinOutcome] = [
            .unresolvedUID(secret),
            .set(uid: secret, requested: 42, status: noErr, actual: 42),
            .set(uid: secret, requested: 42, status: noErr, actual: nil),
            .set(uid: secret, requested: 42, status: noErr, actual: 104),
            .set(uid: secret, requested: 42, status: kAudioUnitErr_InvalidPropertyValue, actual: 104),
        ]

        for outcome in outcomes {
            XCTAssertFalse(
                outcome.logLine?.contains("SERIAL1234") ?? false,
                "UID leaked into an unconditional public line: \(outcome.logLine ?? "")",
            )
        }
    }

    // MARK: - Which device the line names

    /// The load-bearing rule. A pin that took makes the configured device the
    /// answer, and nothing else does.
    func testAnAdoptedPinIsTheDeviceReported() {
        let outcome = MicDevicePinOutcome.set(
            uid: builtIn, requested: 42, status: noErr, actual: 42,
        )

        XCTAssertEqual(outcome.deviceToReport(systemDefault: 104), 42)
    }

    /// With nothing configured, the engine binds its input unit to a private
    /// aggregate that follows the system default, so the default is the only
    /// answer worth printing. Reporting the unit's own device here was measured
    /// to yield `CADefaultDeviceAggregate-<n>-0`, which names no microphone.
    func testNothingConfiguredReportsTheSystemDefault() {
        XCTAssertEqual(MicDevicePinOutcome.notRequested.deviceToReport(systemDefault: 104), 104)
    }

    /// Every pin that demonstrably did not put the unit on the configured
    /// device lands on the system default, because that is where the unit
    /// actually is in each of them: nothing was attempted, the set was refused
    /// so the unit never moved, or the unit answered with another device.
    func testEveryDisprovenPinReportsTheSystemDefault() {
        let disproven: [MicDevicePinOutcome] = [
            .unresolvedUID(builtIn),
            .set(uid: builtIn, requested: 42, status: kAudioUnitErr_InvalidPropertyValue, actual: 104),
            .set(uid: builtIn, requested: 42, status: noErr, actual: 104),
        ]

        for outcome in disproven {
            XCTAssertEqual(
                outcome.deviceToReport(systemDefault: 104), 104,
                "must not claim the configured device for \(outcome)",
            )
        }
    }

    /// The arm the second review round added. A set that was accepted and could
    /// not be read back is not evidence that the unit is on the default: the
    /// acceptance is the only evidence there is, and it points at the
    /// configured device. Naming the default here would state the opposite of
    /// what was measured, which is the failure this whole type exists to end.
    func testAnUnconfirmedPinStillNamesTheConfiguredDevice() {
        let outcome = MicDevicePinOutcome.set(
            uid: builtIn, requested: 42, status: noErr, actual: nil,
        )

        XCTAssertEqual(outcome.deviceToReport(systemDefault: 104), 42)
    }

    func testNoDefaultAndNoPinLeavesNothingToName() {
        XCTAssertNil(MicDevicePinOutcome.notRequested.deviceToReport(systemDefault: nil))
    }

    // MARK: - What the line reads like

    func testTheLineNamesTheDeviceItWasGiven() {
        let line = micInputDeviceLogLine(
            device: MicInputDevice(uid: "BuiltInMicrophoneDevice", name: "MacBook Pro Microphone"),
            hardwareRate: 48000, hardwareChannels: 1,
        )

        XCTAssertEqual(
            line,
            "[debug] Mic input device: name=MacBook Pro Microphone uid=BuiltInMicrophoneDevice"
                + " hwRate=48000.000000 hwChannels=1",
        )
    }

    /// The rate rendering is load-bearing: field reports are grepped for it, and
    /// os_log printed a Double as `%f`. A plain Swift interpolation would emit
    /// `48000.0` and silently break every existing search.
    func testTheRateKeepsTheRenderingFieldReportsWereGreppedFor() {
        let line = micInputDeviceLogLine(
            device: MicInputDevice(uid: "u", name: "n"), hardwareRate: 24000, hardwareChannels: 1,
        )

        XCTAssertTrue(line.contains("hwRate=24000.000000"), line)
    }

    /// CoreAudio not answering must not change the shape of the line.
    func testAnUnreadableDeviceKeepsTheLineShape() {
        let line = micInputDeviceLogLine(device: nil, hardwareRate: 48000, hardwareChannels: 2)

        XCTAssertTrue(line.contains("name=? uid=?"), line)
        XCTAssertTrue(line.contains("hwChannels=2"), line)
    }
}
