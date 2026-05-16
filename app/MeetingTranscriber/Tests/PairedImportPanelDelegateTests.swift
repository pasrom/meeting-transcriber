import AppKit
@testable import MeetingTranscriber
import XCTest

@MainActor
final class PairedImportPanelDelegateTests: XCTestCase {
    func testInitCreatesAccessoryViewWithLabel() {
        let delegate = PairedImportPanelDelegate()
        XCTAssertFalse(delegate.accessoryView.subviews.isEmpty, "accessory view should contain the status label")
        let labels = delegate.accessoryView.subviews.compactMap { $0 as? NSTextField }
        XCTAssertEqual(labels.count, 1)
        XCTAssertEqual(labels.first?.alignment, .center)
    }

    func testPanelSelectionDidChangeWithNilSenderShowsBlank() {
        let delegate = PairedImportPanelDelegate()
        delegate.panelSelectionDidChange(nil)
        let label = (delegate.accessoryView.subviews.compactMap { $0 as? NSTextField }).first
        XCTAssertEqual(label?.stringValue, " ", "empty selection keeps a non-empty string so the label preserves its baseline height")
    }

    func testPanelSelectionDidChangeWithEmptyPanelShowsBlank() {
        let delegate = PairedImportPanelDelegate()
        let panel = NSOpenPanel()
        // Fresh panel has no urls — same fallback as nil sender.
        delegate.panelSelectionDidChange(panel)
        let label = (delegate.accessoryView.subviews.compactMap { $0 as? NSTextField }).first
        XCTAssertEqual(label?.stringValue, " ")
    }

    func testPanelSelectionDidChangeWithNonPanelSenderShowsBlank() {
        // Defensive branch: sender is not an NSOpenPanel → urls fallback to [].
        let delegate = PairedImportPanelDelegate()
        delegate.panelSelectionDidChange(NSObject())
        let label = (delegate.accessoryView.subviews.compactMap { $0 as? NSTextField }).first
        XCTAssertEqual(label?.stringValue, " ")
    }
}
