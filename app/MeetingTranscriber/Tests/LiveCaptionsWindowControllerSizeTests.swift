@testable import MeetingTranscriber
import XCTest

/// The invariant the preset design exists for: the font and the panel can
/// never be observed at different presets. `resizedFrame` is pure and pinned
/// elsewhere; these pin the other half, that the controller actually pushes
/// the preset into the state the overlay reads its font from. Neither needs
/// a panel: `apply` returns before touching one while none exists.
@MainActor
final class LiveCaptionsWindowControllerSizeTests: XCTestCase {
    /// A throwaway suite per test, so the saved-origin assertions never read
    /// or write the real panel position.
    private func makeDefaults() throws -> UserDefaults {
        let name = "captions-window-\(getpid())-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        addTeardownBlock { defaults.removePersistentDomain(forName: name) }
        return defaults
    }

    func testInitPushesSizeIntoState() throws {
        let state = LiveCaptionsState()
        _ = try LiveCaptionsWindowController(state: state, size: .large, defaults: makeDefaults())
        XCTAssertEqual(state.size, .large)
    }

    func testApplyPushesSizeIntoState() throws {
        let state = LiveCaptionsState()
        let controller = try LiveCaptionsWindowController(state: state, size: .large, defaults: makeDefaults())
        controller.apply(size: .small)
        XCTAssertEqual(state.size, .small)
    }

    /// The controller exists from launch while the panel is only made at the
    /// first recording, so a preset change made in Settings beforehand takes
    /// the no-panel path. The saved origin is a bottom-left corner for the
    /// old width; left as it is, the next `show()` would put the bar's centre
    /// half the width delta off. Re-centring the saved origin keeps the bar
    /// where the user parked it.
    func testApplyWithoutAPanelRecentresTheSavedOrigin() throws {
        let defaults = try makeDefaults()
        defaults.set(["x": 396.0, "y": 115.0], forKey: LiveCaptionsWindowController.originDefaultsKey)
        let controller = LiveCaptionsWindowController(state: LiveCaptionsState(), size: .medium, defaults: defaults)

        controller.apply(size: .small)

        let saved = defaults.dictionary(forKey: LiveCaptionsWindowController.originDefaultsKey)
        // medium 720 → small 520: the left edge moves right by 100 to keep the centre at 756.
        XCTAssertEqual(saved?["x"] as? Double, 496)
        XCTAssertEqual(saved?["y"] as? Double, 115)
    }

    func testApplyWithoutAPanelAndNoSavedOriginSavesNothing() throws {
        let defaults = try makeDefaults()
        let controller = LiveCaptionsWindowController(state: LiveCaptionsState(), size: .medium, defaults: defaults)
        controller.apply(size: .large)
        XCTAssertNil(defaults.dictionary(forKey: LiveCaptionsWindowController.originDefaultsKey))
    }
}
