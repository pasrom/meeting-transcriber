import AppKit
@testable import MeetingTranscriber
import SwiftUI
import ViewInspector
import XCTest

@MainActor
final class HelpBadgeTests: XCTestCase {
    // swiftlint:disable:next implicitly_unwrapped_optional
    private var defaults: UserDefaults!
    // swiftlint:disable:next implicitly_unwrapped_optional
    private var testSuiteName: String!

    /// Per-test isolated UserDefaults suite (same pattern as SettingsViewTests).
    /// Avoids `swift test --parallel` plist races and prevents leaking into the
    /// dev app's `.standard` plist.
    override func setUp() async throws {
        try await super.setUp()
        testSuiteName = "HelpBadgeTests-\(getpid())-\(UUID().uuidString)"
        guard let suite = UserDefaults(suiteName: testSuiteName) else {
            XCTFail("Could not create test UserDefaults suite")
            return
        }
        defaults = suite
    }

    override func tearDown() async throws {
        defaults?.removePersistentDomain(forName: testSuiteName)
        defaults = nil
        testSuiteName = nil
        try await super.tearDown()
    }

    // MARK: - Helpers

    private func iconNames(for badge: HelpBadge) throws -> [String] {
        let images = try badge.inspect().findAll(ViewType.Image.self)
        return images.compactMap { try? $0.actualImage().name() }
    }

    private func infoBadgeCount(in view: AudioSettingsView) throws -> Int {
        let images = try view.inspect().findAll(ViewType.Image.self)
        return images.compactMap { try? $0.actualImage().name() }.count { $0 == "info.circle" }
    }

    // MARK: - Badge rendering

    func testRendersInfoCircleIcon() throws {
        XCTAssertTrue(try iconNames(for: HelpBadge(text: "Explains the thing")).contains("info.circle"))
    }

    func testBadgeIsATappableButtonCarryingTheHelpText() throws {
        // The badge is a real Button carrying the help string. NOTE: ViewInspector
        // 0.10.3 cannot inspect native `.popover` content, so `find(text:)` here
        // matches the `.help()` tooltip modifier, not the popover Text. This is a
        // declarative check; it does not exercise tap -> popover presentation.
        let sut = HelpBadge(text: "Explains the thing")
        XCTAssertNoThrow(try sut.inspect().find(ViewType.Button.self))
        XCTAssertNoThrow(try sut.inspect().find(text: "Explains the thing"))
    }

    // MARK: - Behavioural (hosted)

    /// Clicking the badge presents the popover. This is the only test that
    /// exercises the tap -> popover path and the popover's content builder;
    /// ViewInspector 0.10.3 can't reach native `.popover` content, so it hosts
    /// the view in a real NSWindow (the popover is an AppKit window).
    func testClickingBadgePresentsPopover() throws {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: 60),
            styleMask: [.titled],
            backing: .buffered,
            defer: false,
        )
        defer { window.orderOut(nil) }
        window.contentView = NSHostingView(rootView: HelpBadge(text: "hello"))
        window.orderFront(nil)
        window.layoutIfNeeded()

        func buttons(in view: NSView) -> [NSButton] {
            ((view as? NSButton).map { [$0] } ?? []) + view.subviews.flatMap(buttons(in:))
        }
        func visiblePopoverWindows() -> Int {
            NSApp.windows.count { String(describing: type(of: $0)).contains("Popover") && $0.isVisible }
        }

        let content = try XCTUnwrap(window.contentView)
        let badge = try XCTUnwrap(buttons(in: content).first, "no NSButton hosted for the badge")
        let before = visiblePopoverWindows()
        badge.performClick(nil)

        // Popover presentation is async; pump the run loop until it appears.
        let deadline = Date(timeIntervalSinceNow: 2)
        while visiblePopoverWindows() == before, Date() < deadline {
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
        }
        XCTAssertEqual(visiblePopoverWindows(), before + 1, "clicking the badge should present its popover")
    }

    // MARK: - HelpfulToggle

    /// The badge must be a sibling of the toggle (own hit target, separately
    /// focusable), so both a HelpBadge and the Toggle live in the same row.
    func testHelpfulToggleRendersLabelBadgeAndToggle() throws {
        let body = try HelpfulToggle(title: "My Option", help: "the help text", isOn: .constant(false)).inspect()
        XCTAssertNoThrow(try body.find(text: "My Option"))
        XCTAssertNoThrow(try body.find(ViewType.Toggle.self))
        // The help param must reach the badge (found via its `.help()` tooltip;
        // popover content is not inspectable), not just render some badge.
        XCTAssertNoThrow(try body.find(text: "the help text"))
        let names = body.findAll(ViewType.Image.self).compactMap { try? $0.actualImage().name() }
        XCTAssertTrue(names.contains("info.circle"))
    }

    /// The badge must be a SIBLING of the Toggle, never nested inside its label:
    /// nesting folds it into the toggle's single accessibility element, so
    /// VoiceOver cannot focus the badge. This is the one zero-scaffolding
    /// automated guard for that regression (red if the badge moves into the
    /// Toggle's label, green while it stays a sibling).
    func testHelpfulToggleKeepsBadgeOutsideToggleSubtree() throws {
        let toggle = try HelpfulToggle(title: "T", help: "h", isOn: .constant(false))
            .inspect().find(ViewType.Toggle.self)
        XCTAssertThrowsError(
            try toggle.find(ViewType.Button.self),
            "the help badge must not live inside the Toggle's label",
        )
    }

    // MARK: - Catalog

    func testHelpCatalogStringsAreNonEmpty() {
        XCTAssertFalse(SettingsHelp.vad.isEmpty)
        XCTAssertFalse(SettingsHelp.silentCaptureChannel.isEmpty)
        XCTAssertFalse(SettingsHelp.asymmetricSilenceWarning.isEmpty)
    }

    // MARK: - Adoption in AudioSettingsView (issue #505)

    /// VAD toggle + Detect Silent Capture Channel toggle + Warn-after row each
    /// carry a clickable info badge. All three rows are visible with defaults
    /// (perChannelIndicatorEnabled defaults to true → warn-after row shown).
    func testAudioTabShowsHelpBadgesForNamedOptions() throws {
        let settings = AppSettings(defaults: defaults)
        settings.perChannelIndicatorEnabled = true
        XCTAssertEqual(try infoBadgeCount(in: AudioSettingsView(settings: settings)), 3)
    }

    /// The warn-after badge lives on the conditional slider row, so it drops
    /// out with the row when per-channel detection is off.
    func testWarnAfterHelpBadgeHiddenWhenDetectionOff() throws {
        let settings = AppSettings(defaults: defaults)
        settings.perChannelIndicatorEnabled = false
        XCTAssertEqual(try infoBadgeCount(in: AudioSettingsView(settings: settings)), 2)
    }

    /// Each option must carry ITS help string (not merely some badge), so a
    /// swapped/empty SettingsHelp constant is caught; the count checks alone
    /// would not notice. The catalog strings are found via each badge's
    /// `.help()` tooltip (ViewInspector can't inspect popover content).
    func testAudioTabWiresEachOptionsHelpText() throws {
        let settings = AppSettings(defaults: defaults)
        settings.perChannelIndicatorEnabled = true
        let body = try AudioSettingsView(settings: settings).inspect()
        XCTAssertNoThrow(try body.find(text: SettingsHelp.vad))
        XCTAssertNoThrow(try body.find(text: SettingsHelp.silentCaptureChannel))
        XCTAssertNoThrow(try body.find(text: SettingsHelp.asymmetricSilenceWarning))
    }
}
