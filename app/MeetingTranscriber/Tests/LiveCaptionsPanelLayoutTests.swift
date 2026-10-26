import AppKit
@testable import MeetingTranscriber
import XCTest

/// Exercise the actual caption panel/NSHostingView boundary. Reflection over
/// the SwiftUI view cannot detect AppKit moving a window during text updates.
@MainActor
final class LiveCaptionsPanelLayoutTests: XCTestCase {
    func testCaptionUpdatesKeepPanelFrameFixed() async throws {
        try XCTSkipIf(NSScreen.main == nil, "no screen to place the panel on")
        let suite = "captions-layout-\(getpid())-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { DefaultsSuite.remove(suite) }
        let state = LiveCaptionsState()
        state.setActiveBackend("Whisper · Translate to English")
        let controller = LiveCaptionsWindowController(state: state, defaults: defaults)
        let before = Set(NSApplication.shared.windows.map(ObjectIdentifier.init))
        controller.show()
        defer { controller.hide() }
        let panel = try XCTUnwrap(NSApplication.shared.windows.first { window in
            !before.contains(ObjectIdentifier(window)) && window.identifier == LiveCaptionsWindowController.panelIdentifier
        })
        let expected = panel.frame
        let sentence = "We will review the project milestones and discuss the next steps with the team. "
        for update in 0 ..< 16 {
            let text = String(repeating: sentence, count: update % 4 + 1)
            state.applyPartial(text, channel: .app)
            state.applyPartial(text, channel: .mic)
            if update % 2 == 1 {
                state.applyFinalized(text, channel: .app)
                state.applyFinalized(text, channel: .mic)
            }
            // Let SwiftUI render the state change and finish its 150 ms animation.
            try await Task.sleep(nanoseconds: 200_000_000)
            panel.contentView?.layoutSubtreeIfNeeded()
            XCTAssertEqual(panel.frame, expected, "Caption update \(update) moved/resized the panel")
        }
        XCTAssertNil(defaults.dictionary(forKey: LiveCaptionsWindowController.originDefaultsKey))
        state.clear()
        try await Task.sleep(nanoseconds: 200_000_000)
        panel.contentView?.layoutSubtreeIfNeeded()
        XCTAssertEqual(panel.frame, expected, "Clearing captions moved/resized the panel")
    }
}
