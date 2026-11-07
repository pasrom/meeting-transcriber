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
        XCTAssertNil(GlobalHotkey(keyCode: UInt16(kVK_F5), modifiers: [], characters: "\u{F708}"), "a media key or an app's own")
    }

    func testF13ToF20NeedNoModifier() throws {
        let hotkey = try XCTUnwrap(GlobalHotkey(keyCode: UInt16(kVK_F13), modifiers: [.function], characters: "\u{F710}"))
        XCTAssertEqual(hotkey.displayName, "F13")
        XCTAssertEqual(hotkey.carbonModifiers, 0)
        XCTAssertNil(hotkey.conflict(with: []))
        XCTAssertEqual(hotkey.menuShortcut?.modifiers, [])
        XCTAssertNil(try conflict(kVK_F20, [.shift], "\u{F717}"))
    }

    /// The key of a shortcut is read off the layout: on AZERTY the key at the
    /// ANSI A position types "q", and the one at the Q position types "a".
    func testAReservedShortcutFollowsTheKeyboardLayout() throws {
        let azerty: (UInt32) -> String? = { [UInt32(kVK_ANSI_A): "q", UInt32(kVK_ANSI_Q): "a"][$0] }
        let atA = try XCTUnwrap(GlobalHotkey(keyCode: UInt16(kVK_ANSI_A), modifiers: [.control, .command], characters: "q"))
        let atQ = try XCTUnwrap(GlobalHotkey(keyCode: UInt16(kVK_ANSI_Q), modifiers: [.control, .command], characters: "a"))
        XCTAssertNotNil(atA.conflict(with: [], layoutKey: azerty), "⌃⌘Q, lock screen")
        XCTAssertNil(atQ.conflict(with: [], layoutKey: azerty), "⌃⌘A")
    }

    /// Space and Return type the same on every layout, so the real lookup can be asked.
    func testTheLayoutNamesAKeyCode() {
        XCTAssertEqual(GlobalHotkey.layoutKey(forKeyCode: UInt32(kVK_Space)), " ")
        XCTAssertEqual(GlobalHotkey.layoutKey(forKeyCode: UInt32(kVK_Return)), "\r")
    }

    private func conflict(
        _ keyCode: Int, _ modifiers: NSEvent.ModifierFlags, _ characters: String, system: [SystemShortcut] = [],
    ) throws -> String? {
        try XCTUnwrap(GlobalHotkey(keyCode: UInt16(keyCode), modifiers: modifiers, characters: characters))
            .conflict(with: system) { _ in characters }
    }

    /// What apps bind and what types symbols: one of ⌘, ⌃ or ⌥, with or without Shift.
    func testOneModifierOnAKeyIsRefused() throws {
        XCTAssertNotNil(try conflict(kVK_ANSI_Q, [.command], "q"))
        XCTAssertNotNil(try conflict(kVK_ANSI_C, [.command, .capsLock], "C"))
        XCTAssertNotNil(try conflict(kVK_ANSI_M, [.command, .shift], "m"), "a meeting app's own mute")
        XCTAssertNotNil(try conflict(kVK_ANSI_C, [.control], "c"), "interrupt in a terminal")
        XCTAssertNotNil(try conflict(kVK_ANSI_L, [.option], "l"), "types @ on a German layout")
        XCTAssertNotNil(try conflict(kVK_Delete, [.command], "\u{7F}"))
        XCTAssertNotNil(try conflict(kVK_Tab, [.control], "\t"))
        XCTAssertNotNil(try conflict(kVK_Space, [.command], " "))
    }

    func testTwoModifiersOnAKeyAreAccepted() throws {
        XCTAssertNil(try conflict(kVK_ANSI_Q, [.command, .option], "q"))
        XCTAssertNil(try conflict(kVK_ANSI_M, [.control, .option], "m"))
    }

    func testAFunctionKeyNeedsOnlyOneModifier() throws {
        XCTAssertNil(try conflict(kVK_F5, [.control, .function], "\u{F708}"))
        XCTAssertNil(try conflict(kVK_F20, [.option], "\u{F717}"))
    }

    /// Arrows carry the `.function` flag as F-keys do, and ⌘← is a text shortcut.
    func testAnArrowIsNotAFunctionKey() throws {
        XCTAssertNotNil(try conflict(kVK_LeftArrow, [.command, .function], "\u{F702}"))
    }

    func testCommonTwoModifierShortcutsAreRefused() throws {
        XCTAssertNotNil(try conflict(kVK_ANSI_H, [.option, .command], "h"), "hide others")
        XCTAssertNotNil(try conflict(kVK_ANSI_F, [.control, .command], "f"), "full screen")
        XCTAssertNotNil(try conflict(kVK_Space, [.control, .command], " "), "emoji picker")
        XCTAssertNil(try conflict(kVK_ANSI_H, [.option, .command, .shift], "h"))
    }

    /// ⌘⇧4 as `CopySymbolicHotKeys` reports a screenshot shortcut, Carbon modifiers.
    private let screenshot = SystemShortcut(keyCode: UInt32(kVK_ANSI_4), carbonModifiers: UInt32(cmdKey | shiftKey))

    func testAnEnabledSystemShortcutIsRefused() throws {
        let message = try XCTUnwrap(conflict(kVK_ANSI_4, [.command, .shift], "4", system: [screenshot]))
        XCTAssertTrue(message.contains("macOS shortcut"))
    }

    /// The system list carries bits beyond the four modifiers, such as Fn on a
    /// function key; they must not hide a match.
    func testASystemShortcutMatchesDespiteExtraModifierBits() throws {
        let withFn = SystemShortcut(keyCode: screenshot.keyCode, carbonModifiers: screenshot.carbonModifiers | 0x20000)
        XCTAssertNotNil(try conflict(kVK_ANSI_4, [.command, .shift], "4", system: [withFn]))
    }

    func testTheSameKeyWithOtherModifiersIsNotASystemShortcut() throws {
        XCTAssertNil(try conflict(kVK_ANSI_4, [.command, .option], "4", system: [screenshot]))
    }

    /// Whether the real list can be read at all; its content is the machine's.
    func testTheSystemListsItsShortcuts() {
        XCTAssertFalse(GlobalHotkey.enabledSystemShortcuts().isEmpty)
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

    func testAFunctionKeyIsNamedAndShownInTheMenuByItsKeyCode() throws {
        let hotkey = try XCTUnwrap(GlobalHotkey(keyCode: UInt16(kVK_F19), modifiers: [.control], characters: "x"))
        XCTAssertEqual(hotkey.displayName, "⌃F19")
        XCTAssertEqual(hotkey.menuShortcut?.key.character, "\u{F716}", "NSF19FunctionKey")
    }

    /// "ß" uppercases to "SS", which would name the key S.
    func testAKeyWhoseUppercaseIsLongerKeepsItsCharacter() throws {
        let hotkey = try XCTUnwrap(GlobalHotkey(keyCode: UInt16(kVK_ANSI_Minus), modifiers: [.option, .command], characters: "ß"))
        XCTAssertEqual(hotkey.displayName, "⌥⌘ß")
        XCTAssertEqual(hotkey.menuShortcut?.key.character, "ß")
    }

    func testMenuShortcutCarriesControlAndShift() throws {
        let hotkey = try XCTUnwrap(GlobalHotkey(keyCode: 46, modifiers: [.control, .shift], characters: "m"))
        XCTAssertEqual(hotkey.menuShortcut?.modifiers, [.control, .shift])
    }

    func testSurvivesSettingsEncoding() throws {
        let hotkey = try XCTUnwrap(GlobalHotkey(keyCode: 46, modifiers: [.control, .option], characters: "m"))
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
            onOpenProtocol: { _ in }, onOpenProtocolsFolder: {},
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
        let defaults = try XCTUnwrap(DefaultsSuite.open(suite))
        addTeardownBlock { DefaultsSuite.remove(suite) }
        let settings = AppSettings(defaults: defaults)
        XCTAssertFalse(settings.startRecordingsMicMuted)
        XCTAssertNil(settings.micMuteHotkey)
    }

    func testStartMutedToggleWritesBackToSettings() throws {
        let suite = "mic-mute-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(DefaultsSuite.open(suite))
        addTeardownBlock { DefaultsSuite.remove(suite) }
        let settings = AppSettings(defaults: defaults)
        let toggle = try AudioSettingsView(settings: settings).inspect()
            .find(viewWithAccessibilityIdentifier: A11yID.startRecordingsMicMutedToggle)
        try toggle.find(ViewType.Toggle.self).tap()
        XCTAssertTrue(settings.startRecordingsMicMuted)
    }

    func testShortcutButtonNamesTheSetShortcutAndClearRemovesIt() throws {
        var stored = GlobalHotkey(keyCode: 46, modifiers: [.control, .option], characters: "m")
        let row = MicMuteHotkeyRow(hotkey: Binding(get: { stored }, set: { stored = $0 }))
        XCTAssertEqual(try row.inspect().find(button: "⌃⌥M").accessibilityIdentifier(), A11yID.micMuteHotkeyButton)

        try row.inspect().find(button: "Clear").tap()
        XCTAssertNil(stored)
    }

    private func capture(
        _ keyCode: Int, _ modifiers: NSEvent.ModifierFlags, _ characters: String?, system: [SystemShortcut] = [],
    ) -> MicMuteHotkeyRow.CaptureOutcome {
        MicMuteHotkeyRow.capture(keyCode: UInt16(keyCode), modifiers: modifiers, characters: characters) { system }
    }

    func testCaptureAcceptsACombinationWithAModifier() throws {
        let expected = try XCTUnwrap(GlobalHotkey(keyCode: 46, modifiers: [.control, .option], characters: "m"))
        XCTAssertEqual(capture(kVK_ANSI_M, [.control, .option], "m"), .accept(expected))
    }

    func testCaptureKeepsListeningOnAPlainKey() {
        XCTAssertEqual(capture(kVK_ANSI_M, [], "m"), .keepListening)
        XCTAssertEqual(capture(kVK_F5, [.function], "\u{F708}"), .keepListening)
    }

    func testEscapeCancelsCaptureEvenWithAModifier() {
        XCTAssertEqual(capture(kVK_Escape, [.control], "\u{1B}"), .cancel)
    }

    private func isRefused(_ outcome: MicMuteHotkeyRow.CaptureOutcome) -> Bool {
        if case .refuse = outcome { return true }
        return false
    }

    func testCaptureRefusesAStandardOrSystemShortcut() {
        XCTAssertTrue(isRefused(capture(kVK_ANSI_Q, [.command], "q")), "⌘Q")
        let system = SystemShortcut(keyCode: UInt32(kVK_ANSI_M), carbonModifiers: UInt32(controlKey | optionKey))
        XCTAssertTrue(isRefused(capture(kVK_ANSI_M, [.control, .option], "m", system: [system])), "an enabled macOS shortcut")
    }

    func testHotkeyPersists() throws {
        let suite = "mic-mute-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(DefaultsSuite.open(suite))
        addTeardownBlock { DefaultsSuite.remove(suite) }
        let hotkey = try XCTUnwrap(GlobalHotkey(keyCode: 46, modifiers: [.control, .option], characters: "m"))
        AppSettings(defaults: defaults).micMuteHotkey = hotkey
        XCTAssertEqual(AppSettings(defaults: defaults).micMuteHotkey, hotkey)
    }
}

/// The real Carbon registrar, which needs no permission. ⌃⌥⇧F19 so no shortcut
/// the machine running the tests uses is taken for the test's length.
@MainActor
final class GlobalHotkeyRegistrarTests: XCTestCase {
    private func makeHotkey() throws -> GlobalHotkey {
        try XCTUnwrap(GlobalHotkey(keyCode: UInt16(kVK_F19), modifiers: [.control, .option, .shift], characters: "x"))
    }

    /// Delivers a hotkey press the way Carbon does, to the handler on the
    /// dispatcher target, carrying the ID of the registration it is for.
    private func press(signature: OSType = GlobalHotkey.carbonSignature) throws {
        var event: EventRef?
        XCTAssertEqual(
            CreateEvent(nil, OSType(kEventClassKeyboard), UInt32(kEventHotKeyPressed), 0, EventAttributes(kEventAttributeNone), &event),
            noErr,
        )
        let created = try XCTUnwrap(event)
        defer { ReleaseEvent(created) }
        var id = EventHotKeyID(signature: signature, id: GlobalHotkey.carbonID)
        XCTAssertEqual(
            SetEventParameter(
                created, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                MemoryLayout<EventHotKeyID>.size, &id,
            ),
            noErr,
        )
        SendEventToEventTarget(created, GetEventDispatcherTarget())
    }

    func testARegisteredHotkeyRunsItsActionUntilUnregistered() throws {
        let registrar = GlobalHotkeyRegistrar()
        addTeardownBlock { @MainActor in registrar.unregister() }
        var presses = 0
        XCTAssertTrue(try registrar.register(makeHotkey()) { presses += 1 })
        try press()
        XCTAssertEqual(presses, 1)

        registrar.unregister()
        try press()
        XCTAssertEqual(presses, 1)
    }

    func testAPressForAnotherRegistrationIsIgnored() throws {
        let registrar = GlobalHotkeyRegistrar()
        addTeardownBlock { @MainActor in registrar.unregister() }
        var presses = 0
        XCTAssertTrue(try registrar.register(makeHotkey()) { presses += 1 })
        try press(signature: 0x4F54_4852)
        XCTAssertEqual(presses, 0)
    }

    func testACombinationThisProcessAlreadyHoldsIsRefused() throws {
        let hotkey = try makeHotkey()
        let first = GlobalHotkeyRegistrar()
        let second = GlobalHotkeyRegistrar()
        addTeardownBlock { @MainActor in first.unregister(); second.unregister() }
        XCTAssertTrue(first.register(hotkey) {})
        XCTAssertFalse(second.register(hotkey) {})
    }
}
