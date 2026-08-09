@testable import MeetingTranscriber
import XCTest

/// The grace gate re-locks Confirm and Skip whenever `NamingGraceKey` changes,
/// so these tests are about what counts as "a new grace window". SwiftUI's
/// `.task(id:)` compares by equality, so equality *is* the behaviour.
final class NamingGraceKeyTests: XCTestCase {
    func testSameRevisionAndCountIsTheSameGraceWindow() {
        let revision = UUID()
        XCTAssertEqual(
            NamingGraceKey(revision: revision, pendingJobCount: 1),
            NamingGraceKey(revision: revision, pendingJobCount: 1),
        )
    }

    /// Re-run and job switches replace the data, which is the pre-existing
    /// re-arm trigger.
    func testChangedRevisionStartsANewGraceWindow() {
        XCTAssertNotEqual(
            NamingGraceKey(revision: UUID(), pendingJobCount: 1),
            NamingGraceKey(revision: UUID(), pendingJobCount: 1),
        )
    }

    /// The case the `revision`-only key missed: a second job reaches naming
    /// while the window is already open on the first. That posts
    /// `.showSpeakerNaming`, which force-activates the app — but the displayed
    /// job's data is untouched, so without the count in the key the buttons
    /// would stay live at exactly the moment focus is taken away from whatever
    /// the user was typing in.
    func testAnotherJobArrivingStartsANewGraceWindow() {
        let revision = UUID()
        XCTAssertNotEqual(
            NamingGraceKey(revision: revision, pendingJobCount: 1),
            NamingGraceKey(revision: revision, pendingJobCount: 2),
        )
    }

    /// Resolving one of several pending jobs also re-arms. Slightly more
    /// re-locking than strictly needed, and deliberate: it covers the observed
    /// sequence of two dismissals two seconds apart, where the second landed on
    /// a dialog that had just swapped in under the cursor.
    func testCountDroppingAlsoStartsANewGraceWindow() {
        let revision = UUID()
        XCTAssertNotEqual(
            NamingGraceKey(revision: revision, pendingJobCount: 2),
            NamingGraceKey(revision: revision, pendingJobCount: 1),
        )
    }
}
