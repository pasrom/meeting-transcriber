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

    /// The badge must carry its explanation on exactly ONE affordance.
    ///
    /// `.help()` and the hover popover both fire on hover, so a badge carrying
    /// both renders the same paragraph twice at once: the system tooltip on top
    /// of the popover it was meant to complement. The popover is the single
    /// carrier of the explanation, for sighted users and for VoiceOver alike —
    /// its `Text` is an ordinary accessible element.
    func testBadgeCarriesTheExplanationOnlyOnce() throws {
        let sut = try HelpBadge(text: "Explains the thing").inspect()
        XCTAssertThrowsError(
            try sut.find(ViewType.Button.self).help(),
            "a tooltip plus the hover popover shows the same text twice at once",
        )
        // And not moved into the hint either, which would duplicate it one
        // layer down: spoken in full on focus, then read again from the popover.
        XCTAssertEqual(
            try sut.find(ViewType.Button.self).accessibilityHint().string(),
            "Shows an explanation of this setting",
            "the hint says what the control does; the popover carries the explanation",
        )
        XCTAssertEqual(
            try sut.find(HelpBadge.self).actualView().text, "Explains the thing",
            "the explanation the popover renders is still the one it was given",
        )
    }

    /// Mirror of the badge rule for the row that hosts it. The row carried its
    /// own `.help`, so hovering the badge raised the row tooltip as well.
    func testHelpfulToggleRowCarriesNoTooltipOfItsOwn() throws {
        let row = try HelpfulToggle(title: "T", help: "h", isOn: .constant(false)).inspect()
        // Anchor first. `XCTAssertThrowsError(row.hStack().help())` alone is
        // vacuum-safe in the wrong direction: if the row ever stops being an
        // HStack, `hStack()` throws and the assertion passes without a tooltip
        // ever having been looked for.
        XCTAssertEqual(try row.hStack().find(HelpBadge.self).actualView().text, "h")
        XCTAssertThrowsError(
            try row.hStack().help(),
            "the row tooltip duplicates the badge that already explains the setting",
        )
    }

    // MARK: - Behavioural (hosted)

    /// Clicking the badge presents the popover. This is the only test that
    /// exercises the tap -> popover path and the popover's content builder;
    /// ViewInspector 0.10.3 can't reach native `.popover` content, so it hosts
    /// the view in a real NSWindow (the popover is an AppKit window).
    ///
    /// It asserts that a popover appeared, not what it says, and that is a
    /// real gap rather than an oversight: after the tooltip was dropped the
    /// popover is the only thing that shows this text to anyone. Two ways to
    /// close it were tried and neither works here, so do not spend the time
    /// again. ViewInspector's `popover()` exists but throws
    /// `notSupported` for a native `.popover` unless the view adopts its
    /// hosting pattern, which nothing in this suite uses. Walking the popover
    /// window's `NSView` tree for accessibility strings returns an empty list,
    /// because a SwiftUI `Text`'s accessibility lives in the `AXUIElement`
    /// tree and not on the views — the same asymmetry `/ui/tree` exists for,
    /// and an in-process AX walk is not populated in a bare xctest process.
    /// What still pins the content is that `HelpBadge.text` is asserted above
    /// and the popover renders exactly that property.
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
        // The help param must reach the badge, not just render some badge.
        XCTAssertEqual(
            try body.find(HelpBadge.self).actualView().text,
            "the help text",
        )
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

    // MARK: - The rule, swept

    /// No settings row offers the explanation twice.
    ///
    /// The fix removed three sites that each paired a `HelpBadge` with a
    /// `.help()`, and the three were found by looking at a screenshot. This is
    /// the same question asked of the whole tab at once, so a fourth one is
    /// caught by a test run instead of by noticing it on screen: any view
    /// carrying a tooltip must not have a badge anywhere beneath it, because
    /// both fire on hover and render the same paragraph on top of each other.
    ///
    /// A bare `.help()` with no badge is untouched — that is the older pattern
    /// and it is still fine.
    ///
    /// What it does NOT catch, measured by restoring each of the three original
    /// sites in turn: a tooltip on `HelpBadge` itself. `findAll` matches the
    /// modifier where it is applied, and one inside the badge's own body is not
    /// reachable from the tab. That site is `testBadgeCarriesTheExplanationOnlyOnce`.
    /// Of the other two this sweep catches both, and for the warn-after row it
    /// is the only cover there is.
    func testNoSettingsRowOffersTheExplanationTwice() throws {
        let settings = AppSettings(defaults: defaults)
        settings.perChannelIndicatorEnabled = true

        for (name, view) in try [
            ("Audio", AudioSettingsView(settings: settings).inspect()),
            ("Speakers", SpeakersSettingsView(
                settings: settings,
                recognitionStatsLog: RecognitionStatsLog(),
                stageTimingLog: StageTimingLog(),
                enrollmentDiarizerFactory: nil,
                namingDialogActive: false,
                pipelineBusy: false,
                matcherFactory: { SpeakerMatcher() },
            ).inspect()),
        ] {
            for tooltipped in view.findAll(where: { (try? $0.help()) != nil }) {
                XCTAssertThrowsError(
                    try tooltipped.find(HelpBadge.self),
                    "\(name): a row with a badge must not also carry a tooltip — both fire on hover",
                )
            }
        }
    }

    // MARK: - Catalog

    func testHelpCatalogStringsAreNonEmpty() {
        XCTAssertFalse(SettingsHelp.vad.isEmpty)
        XCTAssertFalse(SettingsHelp.silentCaptureChannel.isEmpty)
        XCTAssertFalse(SettingsHelp.asymmetricSilenceWarning.isEmpty)
        XCTAssertFalse(SettingsHelp.echoDedup.isEmpty)
    }

    // MARK: - Adoption in AudioSettingsView (issue #505)

    /// VAD toggle + echo-dedup toggle + Detect Silent Capture Channel toggle +
    /// Warn-after row each carry a clickable info badge. All four rows are
    /// visible with defaults (perChannelIndicatorEnabled defaults to true →
    /// warn-after row shown).
    func testAudioTabShowsHelpBadgesForNamedOptions() throws {
        let settings = AppSettings(defaults: defaults)
        settings.perChannelIndicatorEnabled = true
        XCTAssertEqual(try infoBadgeCount(in: AudioSettingsView(settings: settings)), 4)
    }

    /// The warn-after badge lives on the conditional slider row, so it drops
    /// out with the row when per-channel detection is off.
    ///
    /// Asserted as a difference of exactly one rather than an absolute count:
    /// the claim is about that row disappearing, and pinning the total made
    /// this test fail for the unrelated reason that the tab gained an option.
    func testWarnAfterHelpBadgeHiddenWhenDetectionOff() throws {
        let settings = AppSettings(defaults: defaults)
        settings.perChannelIndicatorEnabled = true
        let shown = try infoBadgeCount(in: AudioSettingsView(settings: settings))
        settings.perChannelIndicatorEnabled = false
        let hidden = try infoBadgeCount(in: AudioSettingsView(settings: settings))
        XCTAssertEqual(hidden, shown - 1)
    }

    /// Each option must carry ITS help string (not merely some badge), so a
    /// swapped/empty SettingsHelp constant is caught; the count checks alone
    /// would not notice.
    func testAudioTabWiresEachOptionsHelpText() throws {
        let settings = AppSettings(defaults: defaults)
        settings.perChannelIndicatorEnabled = true
        let body = try AudioSettingsView(settings: settings).inspect()
        let texts = body.findAll(HelpBadge.self).compactMap { try? $0.actualView().text }
        XCTAssertTrue(texts.contains(SettingsHelp.vad))
        XCTAssertTrue(texts.contains(SettingsHelp.silentCaptureChannel))
        XCTAssertTrue(texts.contains(SettingsHelp.asymmetricSilenceWarning))
    }
}
