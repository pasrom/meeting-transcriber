@testable import MeetingTranscriber
import XCTest

/// The caption-bar size presets. Each preset couples a font size with the
/// panel dimensions that fit it, so the two cannot drift apart in Settings.
final class LiveCaptionsSizeTests: XCTestCase {
    /// `.medium` is the default, so it must reproduce the metrics the bar
    /// shipped with before the preset existed: an existing install sees no
    /// change on upgrade.
    func testMediumMatchesHistoricalOverlayMetrics() {
        XCTAssertEqual(LiveCaptionsSize.medium.fontSize, 22)
        XCTAssertEqual(LiveCaptionsSize.medium.panelSize, CGSize(width: 720, height: 200))
    }

    func testSmallIsTheCompactPreset() {
        XCTAssertEqual(LiveCaptionsSize.small.fontSize, 16)
        XCTAssertEqual(LiveCaptionsSize.small.panelSize, CGSize(width: 520, height: 160))
    }

    func testLargeIsTheRoomyPreset() {
        XCTAssertEqual(LiveCaptionsSize.large.fontSize, 28)
        XCTAssertEqual(LiveCaptionsSize.large.panelSize, CGSize(width: 920, height: 260))
    }

    /// The fit relation the doc comments promise, so a preset cannot pair a
    /// font with a panel that clips it: five single-line rows (backend label
    /// plus two finals plus two hypotheses) at the overlay's real line heights
    /// (about 1.2 × font size, the label at half that), the 4 pt row spacing
    /// and the 2 × 14 pt vertical padding must fit with one wrapped row of
    /// headroom.
    func testEveryPresetFitsFiveRowsPlusOneWrappedLine() {
        for size in LiveCaptionsSize.allCases {
            let row = size.fontSize * 1.2
            let label = size.labelFontSize * 1.2
            let fiveRows = label + 4 * row + 4 * 4 + 2 * 14
            XCTAssertGreaterThanOrEqual(
                size.panelSize.height, fiveRows + row,
                "\(size) clips a wrapped caption: needs \(fiveRows + row), has \(size.panelSize.height)",
            )
        }
    }

    /// The backend label scales with the preset but never below what AppKit
    /// considers legible; medium keeps the 11 pt it shipped with.
    func testBackendLabelNeverDropsBelowTenPoints() {
        XCTAssertEqual(LiveCaptionsSize.medium.labelFontSize, 11)
        XCTAssertEqual(LiveCaptionsSize.large.labelFontSize, 14)
        XCTAssertEqual(LiveCaptionsSize.small.labelFontSize, 10)
    }

    /// Every metric grows with the preset. A preset whose panel shrank while
    /// its font grew would clip captions, so the ordering is pinned.
    func testPresetsGrowMonotonically() {
        let ordered: [LiveCaptionsSize] = [.small, .medium, .large]
        for (smaller, larger) in zip(ordered, ordered.dropFirst()) {
            XCTAssertLessThan(smaller.fontSize, larger.fontSize)
            XCTAssertLessThan(smaller.panelSize.width, larger.panelSize.width)
            XCTAssertLessThan(smaller.panelSize.height, larger.panelSize.height)
        }
    }

    /// Raw values are what `UserDefaults` stores. A rename that changed them
    /// would silently reset every user's choice to the default.
    func testRawValuesArePinned() {
        XCTAssertEqual(LiveCaptionsSize.small.rawValue, "small")
        XCTAssertEqual(LiveCaptionsSize.medium.rawValue, "medium")
        XCTAssertEqual(LiveCaptionsSize.large.rawValue, "large")
        XCTAssertEqual(LiveCaptionsSize.allCases, [.small, .medium, .large])
    }

    /// Resizing keeps the bar where the user parked it: same bottom edge,
    /// same horizontal centre. Keeping the bottom-left corner instead would
    /// walk a shrinking bar sideways on every change.
    @MainActor
    func testResizedFrameKeepsBottomCentre() {
        let medium = NSRect(x: 100, y: 60, width: 720, height: 200)

        let small = LiveCaptionsWindowController.resizedFrame(medium, to: .small, within: nil)

        XCTAssertEqual(small.size, LiveCaptionsSize.small.panelSize)
        XCTAssertEqual(small.midX, medium.midX)
        XCTAssertEqual(small.minY, medium.minY)
    }

    /// AppKit does not constrain a borderless non-activating panel, so a bar
    /// parked flush against a screen edge would grow past it by half the
    /// width delta. The resized frame is pushed back inside the screen.
    @MainActor
    func testResizedFrameStaysInsideTheScreen() {
        let screen = NSRect(x: 0, y: 0, width: 1512, height: 900)
        let flushRight = NSRect(x: 1512 - 520, y: 60, width: 520, height: 160)
        let flushLeft = NSRect(x: 0, y: 60, width: 520, height: 160)

        let right = LiveCaptionsWindowController.resizedFrame(flushRight, to: .large, within: screen)
        let left = LiveCaptionsWindowController.resizedFrame(flushLeft, to: .large, within: screen)

        XCTAssertEqual(right.maxX, 1512)
        XCTAssertEqual(left.minX, 0)
        XCTAssertEqual(right.size, LiveCaptionsSize.large.panelSize)
    }
}
