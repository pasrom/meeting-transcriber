@testable import MeetingTranscriber
import SwiftUI
import ViewInspector
import XCTest

/// Pins the capability the Identifiers rule in `CLAUDE.md` tells people to rely
/// on: that `Picker` and `Stepper` are locatable by an accessibility identifier
/// attached to the control itself.
///
/// This exists because the rule used to say the opposite, and because
/// `Package.swift` depends on ViewInspector with `from:`, so the pin can move
/// upward without anyone deciding to move it. If this goes red, the rule is
/// stale, not the test.
///
/// Deliberately a probe view rather than a production one: the claim is about
/// the two control types, and tying it to a real screen would make it fail for
/// reasons that have nothing to do with the rule.
private struct ProbeView: View {
    @State private var choice = 1
    @State private var amount = 1.0

    var body: some View {
        VStack {
            Picker("Choice", selection: $choice) {
                Text("One").tag(1)
                Text("Two").tag(2)
            }
            .accessibilityIdentifier("probe-picker")

            Stepper("", value: $amount, step: 0.5)
                .accessibilityIdentifier("probe-stepper")
        }
    }
}

final class ViewInspectorIdentifierTests: XCTestCase {
    /// Two steps, because the identifier lookup returns the modified view and
    /// not the typed control; the second `find` is what makes `select` reachable.
    func testPickerIsFoundByItsIdentifier() throws {
        let picker = try ProbeView().inspect()
            .find(viewWithAccessibilityIdentifier: "probe-picker")
            .find(ViewType.Picker.self)

        XCTAssertEqual(try picker.labelView().text().string(), "Choice")
    }

    func testStepperIsFoundByItsIdentifierAndCanBeDriven() throws {
        let stepper = try ProbeView().inspect()
            .find(viewWithAccessibilityIdentifier: "probe-stepper")
            .find(ViewType.Stepper.self)

        XCTAssertNoThrow(try stepper.increment())
    }

    /// The control that makes the two above mean something: the lookup has to
    /// fail for an identifier nothing carries, or finding one proves nothing.
    func testAnUnknownIdentifierIsNotFound() {
        XCTAssertThrowsError(
            try ProbeView().inspect().find(viewWithAccessibilityIdentifier: "no-such-identifier"),
        )
    }
}
