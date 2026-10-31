// swiftlint:disable single_test_class
import AppKit
import AudioTapLib
import Carbon.HIToolbox
@testable import MeetingTranscriber
import SwiftUI
import ViewInspector
import XCTest

final class GlobalHotkeyTests: XCTestCase {
    func testAModifierIsRequired() {
        XCTAssertNil(GlobalHotkey(keyCode: 46, modifiers: [], characters: "m"))
        XCTAssertNil(GlobalHotkey(keyCode: 46, modifiers: [.shift], characters: "M"))
    }

    func testModifiersMapToCarbonAndTheName() throws {
        let hotkey = try XCTUnwrap(GlobalHotkey(keyCode: 46, modifiers: [.control, .option], characters: "m"))
        XCTAssertEqual(hotkey.keyCode, 46)
        XCTAssertEqual(hotkey.carbonModifiers, UInt32(controlKey | optionKey))
        XCTAssertEqual(hotkey.displayName, "⌃⌥M")
    }

    func testMenuShortcutMatchesTheCombinationWithoutImplyingShift() throws {
        let hotkey = try XCTUnwrap(GlobalHotkey(keyCode: 35, modifiers: [.option, .command], characters: "p"))
        let shortcut = try XCTUnwrap(hotkey.menuShortcut)
        XCTAssertEqual(shortcut.key.character, "p")
        XCTAssertEqual(shortcut.modifiers, [.option, .command])
    }

    func testSurvivesSettingsEncoding() throws {
        let hotkey = try XCTUnwrap(GlobalHotkey(keyCode: 46, modifiers: [.command], characters: "m"))
        let decoded = try JSONDecoder().decode(GlobalHotkey.self, from: JSONEncoder().encode(hotkey))
        XCTAssertEqual(decoded, hotkey)
    }
}

@MainActor
final class MicMuteMenuTests: XCTestCase {
    private func makeView(
        isMicMuted: Bool = false, shortcut: KeyboardShortcut? = nil, onToggle: (() -> Void)?,
    ) -> MenuBarView {
        MenuBarView(
            status: nil, isWatching: true,
            pipelineQueue: PipelineQueue(logDir: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)),
            updateChecker: nil,
            onStartStop: {}, onRecordApp: {}, onRecordMicrophone: {}, noMic: false,
            manualRecordingPendingOrActive: false, onStopManualRecording: nil,
            isMicMuted: isMicMuted, onToggleMicMute: onToggle, micMuteShortcut: shortcut,
            onOpenLastProtocol: {}, onOpenProtocol: { _ in }, onOpenProtocolsFolder: {},
            onOpenSettings: {}, onNameSpeakers: nil, onProcessFiles: {}, onDismissJob: { _ in }, onQuit: {},
        )
    }

    func testNoItemWithoutAMutableRecording() {
        XCTAssertThrowsError(try makeView(onToggle: nil).inspect().find(button: "Mute Mic in Recording"))
    }

    func testMuteItemCallsTheToggle() throws {
        var toggled = false
        try makeView { toggled = true }.inspect().find(button: "Mute Mic in Recording").tap()
        XCTAssertTrue(toggled)
    }

    func testItemFallsBackToCommandMWithNoShortcutSet() {
        let shortcut = makeView {}.micMuteItemShortcut
        XCTAssertEqual(shortcut.key.character, "m")
        XCTAssertEqual(shortcut.modifiers, .command)
    }

    func testASetShortcutReplacesCommandM() {
        let set = KeyboardShortcut("p", modifiers: [.option, .command])
        let shortcut = makeView(shortcut: set) {}.micMuteItemShortcut
        XCTAssertEqual(shortcut.key.character, "p")
        XCTAssertEqual(shortcut.modifiers, [.option, .command])
    }

    func testLabelStaysPlainWithAShortcutSet() {
        let shortcut = KeyboardShortcut("p", modifiers: [.option, .command])
        XCTAssertNoThrow(try makeView(shortcut: shortcut) {}.inspect().find(button: "Mute Mic in Recording"))
    }

    func testMutedStateOffersUnmute() throws {
        XCTAssertNoThrow(try makeView(isMicMuted: true) {}.inspect().find(button: "Unmute Mic in Recording"))
    }
}

@MainActor
final class MicMuteIconTests: XCTestCase {
    func testMutedIconDiffersFromTheRecordingIcon() {
        let plain = MenuBarIcon.image(badge: .recording).tiffRepresentation
        let muted = MenuBarIcon.image(badge: .recording, micMutedOverlay: true).tiffRepresentation
        XCTAssertNotEqual(plain, muted)
    }
}

@MainActor
final class MicMuteWatchLoopTests: XCTestCase {
    private func recordingLoop(_ recorder: MockRecorder) async throws -> WatchLoop {
        let loop = WatchLoop(recorderFactory: { recorder }, pidAliveCheck: { _ in true })
        loop.permissionChecker = { .allHealthy }
        try await loop.startManualRecording(pid: getpid(), appName: "a", title: "t")
        return loop
    }

    func testToggleReachesTheRecorder() async throws {
        let recorder = makeMockRecorder()
        recorder.canMuteMic = true
        let loop = try await recordingLoop(recorder)
        XCTAssertTrue(loop.canMuteMic)

        loop.toggleMicMute()
        XCTAssertTrue(recorder.isMicMuted)
        XCTAssertTrue(loop.isMicMuted)
        loop.toggleMicMute()
        XCTAssertFalse(loop.isMicMuted)
    }

    func testAMuteDoesNotCarryIntoTheNextRecording() async throws {
        let recorder = makeMockRecorder()
        recorder.canMuteMic = true
        let loop = try await recordingLoop(recorder)
        loop.toggleMicMute()

        loop.stopManualRecording()
        XCTAssertFalse(loop.isMicMuted)
        XCTAssertFalse(loop.canMuteMic)
    }

    func testARecorderWithNoOpenMicOffersNoMute() async throws {
        let recorder = makeMockRecorder()
        let loop = try await recordingLoop(recorder)
        XCTAssertFalse(loop.canMuteMic)
        loop.toggleMicMute()
        XCTAssertFalse(loop.isMicMuted)
    }
}

@MainActor
final class MicMuteSettingsTests: XCTestCase {
    func testStartMutedDefaultsOff() throws {
        let suite = "mic-mute-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { DefaultsSuite.remove(suite) }
        let settings = AppSettings(defaults: defaults)
        XCTAssertFalse(settings.startRecordingsMicMuted)
        XCTAssertNil(settings.micMuteHotkey)
    }

    func testHotkeyPersists() throws {
        let suite = "mic-mute-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { DefaultsSuite.remove(suite) }
        let hotkey = try XCTUnwrap(GlobalHotkey(keyCode: 46, modifiers: [.command], characters: "m"))
        AppSettings(defaults: defaults).micMuteHotkey = hotkey
        XCTAssertEqual(AppSettings(defaults: defaults).micMuteHotkey, hotkey)
    }
}
