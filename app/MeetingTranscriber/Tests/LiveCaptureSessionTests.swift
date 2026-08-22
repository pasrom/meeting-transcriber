import AudioTapLib
@testable import MeetingTranscriber
import XCTest

/// The production capture-session factory — the one path that builds a real
/// `AudioCaptureSession`, and the only place that decides what a given build is
/// allowed to open one with.
@MainActor
final class LiveCaptureSessionTests: XCTestCase {
    private func configuration(micDebugFault: DebugTapFault? = nil) -> AudioCaptureConfiguration {
        var config = AudioCaptureConfiguration(
            pids: [], appOutputURL: nil, micOutputURL: nil, sampleRate: 48000, channels: 2,
        )
        config.micDebugFault = micDebugFault
        return config
    }

    /// The guarantee that a shipped binary cannot inject the e2e tap fault, and
    /// the reason it needs a test at all: `micDebugFault` is a `var` on a struct
    /// that ships, so a caller — a config template, a copied configuration, a
    /// mis-merged helper — could set it, and the handler's fault machinery is
    /// compiled into every build. The overwrite here is the only thing standing
    /// between that and a self-triggered device-change restart on every
    /// recording. It was dropped once during this refactor and nothing failed.
    func testTheBuildDecidesTheFaultAndNotTheCaller() {
        let asked = configuration(micDebugFault: DebugTapFault(triggerRestartAfter: 7))

        let allowed = LiveCaptureSession.configurationForThisBuild(asked)

        #if E2E_FAULT_INJECTION
            XCTAssertNotNil(allowed.micDebugFault, "the e2e build is the one that injects the fault")
        #else
            XCTAssertNil(
                allowed.micDebugFault,
                "a shipped build must overwrite whatever the caller set, not carry it through",
            )
        #endif
    }

    /// Everything else the caller asked for survives that overwrite. Written
    /// because the sanitiser copies a ten-field value: clearing one field by
    /// rebuilding the struct instead of mutating a copy would drop the rest
    /// silently, and every one of them decides what gets recorded.
    func testNothingElseIsChangedOnTheWayThrough() {
        let app = URL(fileURLWithPath: "/tmp/stem_app16k_raw.tmp")
        let mic = URL(fileURLWithPath: "/tmp/stem_mic.wav")
        let asked = AudioCaptureConfiguration(
            pids: [11, 22], appOutputURL: app, micOutputURL: mic,
            sampleRate: 44100, channels: 5, micDeviceUID: "device-uid", debugLogging: true,
        )

        let allowed = LiveCaptureSession.configurationForThisBuild(asked)

        XCTAssertEqual(allowed.pids, [11, 22])
        XCTAssertEqual(allowed.appOutputURL, app)
        XCTAssertEqual(allowed.micOutputURL, mic, "the two track URLs must not cross here either")
        XCTAssertEqual(allowed.sampleRate, 44100)
        XCTAssertEqual(allowed.channels, 5)
        XCTAssertEqual(allowed.micDeviceUID, "device-uid")
        XCTAssertTrue(allowed.debugLogging)
    }

    /// `make` builds a session and touches no hardware doing it: the session's
    /// init only stores the configuration, and nothing opens until `start()`.
    /// This is what covers the OS-floor guard on the path every real recording
    /// takes.
    func testMakeBuildsASessionWithoutOpeningAnything() throws {
        XCTAssertNoThrow(try LiveCaptureSession.make(configuration()))
    }
}
