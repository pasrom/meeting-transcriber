@testable import MeetingTranscriber
import XCTest

/// The shortcut is held only while a recording can be muted, and a refusal is
/// told, not swallowed. Driven through a real `WatchLoop` on a mock recorder.
@MainActor
final class MicMuteHotkeySyncTests: XCTestCase {
    private final class SpyRegistrar: HotkeyRegistering {
        var accepts = true
        private(set) var registered: GlobalHotkey?
        private(set) var action: (() -> Void)?

        func register(_ hotkey: GlobalHotkey, action: @escaping () -> Void) -> Bool {
            guard accepts else { return false }

            registered = hotkey
            self.action = action
            return true
        }

        func unregister() {
            registered = nil
            action = nil
        }
    }

    private let hotkey = GlobalHotkey(keyCode: 46, modifiers: [.control, .option], characters: "m")

    private func recording(
        registrar: SpyRegistrar, notifier: RecordingNotifier = RecordingNotifier(), canMute: Bool = true,
    ) async throws -> (WatchingController, WatchLoop, MockRecorder) {
        let controller = try makeWatchingController(
            logDir: makeTempDirectory(prefix: "mic-mute-hotkey"), notifier: notifier, micMuteHotkeyRegistrar: registrar,
        )
        controller.settings.micMuteHotkey = hotkey
        let recorder = makeMockRecorder()
        recorder.canMuteMic = canMute
        let loop = WatchLoop(recorderFactory: { recorder }, pidAliveCheck: { _ in true })
        loop.permissionChecker = { .allHealthy }
        controller.watchLoop = loop
        try await loop.startManualRecording(pid: getpid(), appName: "a", title: "t")
        return (controller, loop, recorder)
    }

    func testHeldWhileARecordingCanBeMutedAndTogglesIt() async throws {
        let registrar = SpyRegistrar()
        let (controller, _, recorder) = try await recording(registrar: registrar)

        XCTAssertEqual(registrar.registered, hotkey)
        // The action holds the controller weakly, as the app's own does.
        withExtendedLifetime(controller) { registrar.action?() }
        XCTAssertTrue(recorder.isMicMuted)
    }

    func testReleasedWhenTheRecordingStops() async throws {
        let registrar = SpyRegistrar()
        let (controller, loop, _) = try await recording(registrar: registrar)

        withExtendedLifetime(controller) { loop.stopManualRecording() }
        XCTAssertNil(registrar.registered)
    }

    func testNotHeldForARecordingWithNoOpenMic() async throws {
        let registrar = SpyRegistrar()
        _ = try await recording(registrar: registrar, canMute: false)

        XCTAssertNil(registrar.registered)
    }

    func testARefusedShortcutIsTold() async throws {
        let registrar = SpyRegistrar()
        registrar.accepts = false
        let notifier = RecordingNotifier()
        _ = try await recording(registrar: registrar, notifier: notifier)

        XCTAssertTrue(notifier.calls.map(\.title).contains("Mic Mute Shortcut Unavailable"))
    }
}
