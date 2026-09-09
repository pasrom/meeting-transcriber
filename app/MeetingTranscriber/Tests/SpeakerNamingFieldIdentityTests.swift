import AppKit
@testable import MeetingTranscriber
import SwiftUI
import XCTest

/// Regression cover for the speaker-naming crash in issue #700, at the lowest
/// layer that reproduces it: the AppKit bridge under `SpeakerNamingView`,
/// hosted in a real `NSWindow`.
///
/// The naming window keeps the same `SpeakerNamingView` slot when it moves on
/// to the next pending job, and `.id(data.meetingTitle)` makes two meetings
/// with the same title one view identity; a Re-run replaces `data` in place
/// for the same job. Rows are keyed by speaker label, so a label that survives
/// such a switch keeps its `NSTextField` and with it the `Coordinator` that
/// SwiftUI created once for it, so nothing that coordinator holds may go
/// stale. When the field was bound to `$names[index]` and the coordinator
/// kept that binding for life, a label that moved to another sorted position (the mic
/// track's cluster count varies between meetings, which shifts every `R_`
/// label) wrote the user's typing into another row, and trapped with "Index
/// out of range" as soon as the new job had fewer speakers than the captured
/// index. That trap is the reporter's crash.
///
/// The measured mechanism is the shift, not a dropped row: a field whose label
/// disappears leaves the window and loses first-responder status, so nothing
/// can type into it. ViewInspector cannot reach the defect either, because it
/// lives in the coordinator SwiftUI retains across updates, which only a hosted
/// view has.
@MainActor
final class SpeakerNamingFieldIdentityTests: XCTestCase {
    /// Stand-in for the naming window host: republishing `data` re-renders the
    /// same view slot with the next job, exactly as the scene does.
    private final class Host: ObservableObject {
        @Published var data: PipelineQueue.SpeakerNamingData
        init(data: PipelineQueue.SpeakerNamingData) {
            self.data = data
        }
    }

    private struct Root: View {
        @ObservedObject var host: Host
        var body: some View {
            SpeakerNamingView(data: host.data, gracePeriod: 0) { _ in }
        }
    }

    /// Both jobs carry this title on purpose: a differing title would give the
    /// second job a fresh view identity and fresh fields, and the scenario
    /// under test would silently stop exercising the retained coordinator.
    private static let sharedTitle = "Weekly sync"

    private func makeData(labels: [String]) -> PipelineQueue.SpeakerNamingData {
        PipelineQueue.SpeakerNamingData(
            jobID: UUID(),
            meetingTitle: Self.sharedTitle,
            mapping: Dictionary(uniqueKeysWithValues: labels.map { ($0, $0) }),
            speakingTimes: Dictionary(uniqueKeysWithValues: labels.map { ($0, 10.0) }),
            embeddings: [:],
            audioPath: nil,
            segments: [],
            participants: [],
            isDualSource: true,
        )
    }

    /// Pump the run loop until `condition` holds or the deadline passes.
    private func pump(timeout: TimeInterval = 5, until condition: () -> Bool) {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
    }

    private func nameFields(in view: NSView) -> [NSTextField] {
        var found: [NSTextField] = []
        if let field = view as? NSTextField, field.accessibilityIdentifier().hasPrefix(A11yID.speakerNamePrefix) {
            found.append(field)
        }
        for sub in view.subviews {
            found += nameFields(in: sub)
        }
        return found
    }

    private func field(_ label: String, in view: NSView) -> NSTextField? {
        nameFields(in: view).first { $0.accessibilityIdentifier() == A11yID.speakerName(label) }
    }

    private func makeWindow(host: Host) -> (NSWindow, NSHostingView<Root>) {
        let hosting = NSHostingView(rootView: Root(host: host))
        hosting.frame = NSRect(x: 0, y: 0, width: 520, height: 760)
        let window = NSWindow(
            contentRect: hosting.frame, styleMask: [.titled], backing: .buffered, defer: false,
        )
        window.contentView = hosting
        window.makeKeyAndOrderFront(nil)
        addTeardownBlock { @MainActor in window.orderOut(nil) }
        return (window, hosting)
    }

    /// Type into the focused field the way keyboard input arrives: through the
    /// field editor's `insertText`, which is what raises `controlTextDidChange`
    /// on the coordinator. A plain `stringValue` write would bypass it.
    private func type(_ text: String, into window: NSWindow) throws {
        let editor = try XCTUnwrap(window.firstResponder as? NSTextView, "focused field must have a field editor")
        editor.insertText(text, replacementRange: editor.selectedRange())
    }

    func testTypingStaysInItsRowWhenLabelChangesPositionAcrossJobSwitch() throws {
        // Job A: one mic speaker, two remote. Sorted, R_SPEAKER_00 sits at index 1.
        let host = Host(data: makeData(labels: ["M_SPEAKER_00", "R_SPEAKER_00", "R_SPEAKER_01"]))
        let (window, hosting) = makeWindow(host: host)
        pump { self.nameFields(in: hosting).count == 3 }
        let fieldBefore = try XCTUnwrap(field("R_SPEAKER_00", in: hosting))

        // Job B, same title: two mic speakers, one remote. R_SPEAKER_00 survives
        // but now sits at index 2; the speaker count is unchanged so the old
        // binding stays in bounds and the defect shows as a misrouted write.
        host.data = makeData(labels: ["M_SPEAKER_00", "M_SPEAKER_01", "R_SPEAKER_00"])
        pump {
            self.field("M_SPEAKER_01", in: hosting) != nil && self.field("R_SPEAKER_01", in: hosting) == nil
        }
        let fieldAfter = try XCTUnwrap(field("R_SPEAKER_00", in: hosting))
        XCTAssertIdentical(
            fieldBefore, fieldAfter,
            "precondition: the surviving label must keep its NSTextField across the switch, or no retained coordinator is exercised",
        )

        XCTAssertTrue(window.makeFirstResponder(fieldAfter))
        try type("Bob", into: window)
        pump { self.nameFields(in: hosting).contains { $0.stringValue == "Bob" } }
        // Do not fold this wait into the pump above. The pump is satisfied the
        // moment the field editor paints "Bob" into the field being typed into,
        // which happens on a correct and a misrouted write alike. A misroute
        // reaches the OTHER row only on the render that follows, so without a
        // wait past that render the negative assertion below would run too
        // early and pass against the defect it exists to catch.
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))

        XCTAssertEqual(
            field("R_SPEAKER_00", in: hosting)?.stringValue, "Bob",
            "typing must stay in the row it was typed into",
        )
        XCTAssertEqual(
            field("M_SPEAKER_01", in: hosting)?.stringValue, "",
            "the row that took over the old index must not receive the typing",
        )
    }
}
