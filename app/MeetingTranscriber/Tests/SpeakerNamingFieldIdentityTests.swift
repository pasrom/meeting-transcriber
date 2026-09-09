import AppKit
@testable import MeetingTranscriber
import SwiftUI
import XCTest

/// Regression cover for the speaker-naming crash in issue #700, at the lowest
/// layer that reproduces it: the AppKit text fields under `SpeakerNamingView`,
/// hosted in a real `NSWindow`.
///
/// The naming window keeps the same `SpeakerNamingView` slot when it moves on
/// to the next pending job, and `.id(data.meetingTitle)` makes two meetings
/// with the same title one view identity; a Re-run replaces `data` in place
/// for the same job. Rows are keyed by speaker label, so a label that survives
/// such a switch keeps its `NSTextField`, and nothing parked on that field may
/// go stale. The crash was exactly that: the field was an `NSViewRepresentable`
/// whose coordinator kept the `$names[index]` binding it was created with, so
/// a label that moved to another sorted position (the mic track's cluster
/// count varies between meetings, which shifts every `R_` label) wrote the
/// user's typing into another row, and trapped with "Index out of range" as
/// soon as the new job had fewer speakers than the captured index. The
/// representable is gone (issue #702) and the plain `TextField` in its place
/// takes a fresh binding on every update; this test is what says so for a
/// hosted, reused field, which ViewInspector never instantiates.
///
/// The measured mechanism is the shift, not a dropped row: a field whose label
/// disappears leaves the window and loses first-responder status, so nothing
/// can type into it.
@MainActor
final class SpeakerNamingFieldIdentityTests: XCTestCase {
    /// Stand-in for the naming window host: republishing `data` re-renders the
    /// same view slot with the next job, exactly as the scene does, and
    /// republishing `pendingJobCount` re-renders it with the same job, as
    /// another job reaching naming does.
    private final class Host: ObservableObject {
        @Published var data: PipelineQueue.SpeakerNamingData
        @Published var pendingJobCount = 1
        init(data: PipelineQueue.SpeakerNamingData) {
            self.data = data
        }
    }

    private struct Root: View {
        @ObservedObject var host: Host
        var body: some View {
            SpeakerNamingView(data: host.data, pendingJobCount: host.pendingJobCount, gracePeriod: 0) { _ in }
        }
    }

    /// Both jobs carry this title on purpose: a differing title would give the
    /// second job a fresh view identity and fresh fields, and the scenario
    /// under test would silently stop exercising the reused field.
    private static let sharedTitle = "Weekly sync"

    /// Every job seeds each field with its label's auto name, unique per label.
    /// It is both the render signal (a field shows it once the job has drawn)
    /// and the locator: the field showing `seed(label)` is that label's field.
    private static func seed(_ label: String) -> String {
        "Auto \(label)"
    }

    private func makeData(labels: [String]) -> PipelineQueue.SpeakerNamingData {
        PipelineQueue.SpeakerNamingData(
            jobID: UUID(),
            meetingTitle: Self.sharedTitle,
            mapping: Dictionary(uniqueKeysWithValues: labels.map { ($0, Self.seed($0)) }),
            speakingTimes: Dictionary(uniqueKeysWithValues: labels.map { ($0, 10.0) }),
            embeddings: [:],
            audioPath: nil,
            segments: [],
            participants: [],
            isDualSource: true,
        )
    }

    // MARK: - Locating a label's field

    /// The dialog's name fields. Assumes they are the only *editable*
    /// `NSTextField`s in it — the label/auto-name rows are non-editable text —
    /// which holds for `SpeakerNamingView` today.
    private func nameFields(in view: NSView) -> [NSTextField] {
        view.descendants(of: NSTextField.self).filter(\.isEditable)
    }

    /// What the fields show, sorted so the set can be compared regardless of
    /// layout order.
    private func shownValues(in view: NSView) -> [String] {
        nameFields(in: view).map(\.stringValue).sorted()
    }

    /// The field for `label`, found by the seed it shows: `seed(label)` is
    /// unique per label, so the editable field whose value equals it is that
    /// row (valid while the field still shows its seed, i.e. before it is
    /// typed into). By value rather than by window position, which CLAUDE.md's
    /// GUI-testing guidance warns against, or by identifier, which does not
    /// survive to the backing `NSTextField` and whose AX form is not served to
    /// a unit test (see the screen-lock note in CLAUDE.md's GUI Testing
    /// section). `shownValues` is checked before each lookup so a half-rendered
    /// switch is never read.
    private func field(_ label: String, in view: NSView) -> NSTextField? {
        nameFields(in: view).first { $0.stringValue == Self.seed(label) }
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
    /// field editor's `insertText`, which is what raises the text-change
    /// notification the binding listens to. A plain `stringValue` write would
    /// bypass it. The whole seed is selected first, as it is when a field takes
    /// focus, so the typing replaces it.
    private func type(_ text: String, into window: NSWindow) throws {
        let editor = try XCTUnwrap(window.firstResponder as? NSTextView, "focused field must have a field editor")
        editor.selectAll(nil)
        editor.insertText(text, replacementRange: editor.selectedRange())
    }

    func testTypingStaysInItsRowWhenLabelChangesPositionAcrossJobSwitch() throws {
        // Job A: one mic speaker, two remote.
        let labelsA = ["M_SPEAKER_00", "R_SPEAKER_00", "R_SPEAKER_01"]
        let host = Host(data: makeData(labels: labelsA))
        let (window, hosting) = makeWindow(host: host)
        pump { self.shownValues(in: hosting) == labelsA.map(Self.seed).sorted() }
        XCTAssertEqual(shownValues(in: hosting), labelsA.map(Self.seed).sorted(), "each row must show its own label's seed")
        let fieldBefore = try XCTUnwrap(field("R_SPEAKER_00", in: hosting))

        // Job B, same title: two mic speakers, one remote. R_SPEAKER_00 survives.
        // The speaker count is unchanged, so a stale positional binding would
        // stay in bounds and the defect would show as a misrouted write.
        let labelsB = ["M_SPEAKER_00", "M_SPEAKER_01", "R_SPEAKER_00"]
        host.data = makeData(labels: labelsB)
        pump { self.shownValues(in: hosting) == labelsB.map(Self.seed).sorted() }
        XCTAssertEqual(shownValues(in: hosting), labelsB.map(Self.seed).sorted(), "the second job must be on screen, each row showing its own seed")
        let fieldAfter = try XCTUnwrap(field("R_SPEAKER_00", in: hosting))
        XCTAssertIdentical(
            fieldBefore, fieldAfter,
            "precondition: the surviving label must keep its NSTextField across the switch, or no reused field is exercised",
        )

        XCTAssertTrue(window.makeFirstResponder(fieldAfter))
        try type("Bob", into: window)
        pump { fieldAfter.stringValue == "Bob" }
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))

        XCTAssertEqual(fieldAfter.stringValue, "Bob", "typing must stay in the row it was typed into")
        XCTAssertEqual(
            field("M_SPEAKER_01", in: hosting)?.stringValue, Self.seed("M_SPEAKER_01"),
            "the row that took over the old index must not receive the typing",
        )

        // What the field shows is not what the view holds: a field editor updates
        // the NSTextField whether or not the binding behind it saw the keystroke.
        // The next render writes the view's state back into every field, so end
        // editing and re-render (another job reaching naming does exactly this):
        // a swallowed write comes back as the seed, a misrouted one shows up in
        // the other row. Measured both ways before this was relied on.
        window.makeFirstResponder(nil)
        host.pendingJobCount = 2
        pump(timeout: 0.3) { false }
        XCTAssertEqual(fieldAfter.stringValue, "Bob", "the binding must hold the typed name: a re-render pushed something else into the field")
        XCTAssertEqual(
            shownValues(in: hosting), [Self.seed("M_SPEAKER_00"), Self.seed("M_SPEAKER_01"), "Bob"].sorted(),
            "after a re-render every row must show what the view holds for its own label",
        )
    }
}
