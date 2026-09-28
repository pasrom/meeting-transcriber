@testable import MeetingTranscriber
import SwiftUI
import ViewInspector
import XCTest

/// `DraftTextField` is what keeps a half-typed setting out of its owner: the
/// keystrokes stay in the draft and the owner hears about the value once, on
/// Return or when the field loses focus. These tests pin that contract on the
/// component itself; which settings key each field commits to is pinned by the
/// view tests that use it.
@MainActor
final class DraftTextFieldTests: XCTestCase {
    private var commits: [String] = []

    private func makeField(value: String, draft: Binding<String>) -> DraftTextField {
        DraftTextField("Repository", value: value, draft: draft) { [self] committed in
            commits.append(committed)
        }
    }

    private func textField(in field: DraftTextField) throws -> InspectableView<ViewType.TextField> {
        try field.inspect().find(ViewType.TextField.self)
    }

    func testTypingChangesOnlyTheDraft() throws {
        let draft = Binding<String>(wrappedValue: "")
        let field = makeField(value: "", draft: draft)

        try textField(in: field).setInput("spert/flix")

        XCTAssertEqual(draft.wrappedValue, "spert/flix")
        XCTAssertEqual(commits, [], "Nothing may reach the owner while the value is still being typed")
    }

    func testReturnCommitsTheDraft() throws {
        let draft = Binding<String>(wrappedValue: "")
        let field = makeField(value: "", draft: draft)

        try textField(in: field).setInput("spert/flix")
        try textField(in: field).callOnSubmit()

        XCTAssertEqual(commits, ["spert/flix"])
    }

    func testLosingFocusCommitsTheDraft() throws {
        let draft = Binding<String>(wrappedValue: "")
        let field = makeField(value: "", draft: draft)

        try textField(in: field).setInput("spert/flix")
        try textField(in: field).callOnChange(oldValue: true, newValue: false)

        XCTAssertEqual(commits, ["spert/flix"])
    }

    /// Clicking a button or switching the Settings tab does not necessarily take
    /// focus from the field, so a field that goes away has to hand over its edit
    /// itself, or the edit is lost with it.
    func testDisappearingCommitsTheDraft() throws {
        let draft = Binding<String>(wrappedValue: "")
        let field = makeField(value: "", draft: draft)

        try textField(in: field).setInput("spert/flix")
        try textField(in: field).callOnDisappear()

        XCTAssertEqual(commits, ["spert/flix"])
    }

    /// Committing an unchanged value would still write the setting, and every
    /// write re-runs the settings observers for nothing.
    func testLosingFocusWithoutAnEditCommitsNothing() throws {
        let draft = Binding<String>(wrappedValue: "spert/flix")
        let field = makeField(value: "spert/flix", draft: draft)

        try textField(in: field).callOnChange(oldValue: true, newValue: false)

        XCTAssertEqual(commits, [])
    }

    /// A folder picker or a Clear button changes the value behind the field; the
    /// field has to show that rather than whatever was typed before.
    func testAValueChangedByTheOwnerReplacesTheDraft() throws {
        let draft = Binding<String>(wrappedValue: "half-ty")
        let field = makeField(value: "half-ty", draft: draft)

        try textField(in: field).callOnChange(oldValue: "half-ty", newValue: "/picked/model")

        XCTAssertEqual(draft.wrappedValue, "/picked/model")
        XCTAssertEqual(commits, [])
    }

    func testTheDraftStartsFromTheOwnersValue() throws {
        let draft = Binding<String>(wrappedValue: "")
        let field = makeField(value: "spert/flix", draft: draft)

        try textField(in: field).callOnAppear()

        XCTAssertEqual(draft.wrappedValue, "spert/flix")
    }
}
