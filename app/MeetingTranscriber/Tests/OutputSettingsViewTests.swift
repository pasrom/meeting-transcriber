@testable import MeetingTranscriber
import ViewInspector
import XCTest

@MainActor
final class OutputSettingsViewTests: XCTestCase {
    // MARK: - OutputSettingsLogic.displayPath

    func testDisplayPathAbbreviatesHomePrefix() {
        let home = URL(fileURLWithPath: "/Users/alice")
        let url = URL(fileURLWithPath: "/Users/alice/Documents/Meetings")
        XCTAssertEqual(
            OutputSettingsLogic.displayPath(for: url, home: home),
            "~/Documents/Meetings",
        )
    }

    func testDisplayPathReturnsFullPathOutsideHome() {
        let home = URL(fileURLWithPath: "/Users/alice")
        let url = URL(fileURLWithPath: "/Volumes/External/Meetings")
        XCTAssertEqual(
            OutputSettingsLogic.displayPath(for: url, home: home),
            "/Volumes/External/Meetings",
        )
    }

    func testDisplayPathExactlyHomeReturnsTilde() {
        let home = URL(fileURLWithPath: "/Users/alice")
        XCTAssertEqual(OutputSettingsLogic.displayPath(for: home, home: home), "~")
    }

    func testDisplayPathDifferentUserHomeReturnsFull() {
        let home = URL(fileURLWithPath: "/Users/alice")
        let url = URL(fileURLWithPath: "/Users/bob/Documents")
        XCTAssertEqual(
            OutputSettingsLogic.displayPath(for: url, home: home),
            "/Users/bob/Documents",
        )
    }

    /// Regression guard: a naive `hasPrefix` match treats `/Users/alicebob/foo`
    /// as inside `/Users/alice` and yields `~bob/foo`. Boundary must be a path
    /// component (`/` or end-of-string).
    func testDisplayPathDoesNotMatchAcrossComponentBoundary() {
        let home = URL(fileURLWithPath: "/Users/alice")
        let url = URL(fileURLWithPath: "/Users/alicebob/foo")
        XCTAssertEqual(
            OutputSettingsLogic.displayPath(for: url, home: home),
            "/Users/alicebob/foo",
        )
    }

    // MARK: - OutputSettingsLogic.mergePickerOptions

    func testMergePickerOptionsPrependsSelectedWhenAbsent() {
        let result = OutputSettingsLogic.mergePickerOptions(
            available: ["gpt-4", "gpt-3.5"], selected: "custom-tag:latest",
        )
        XCTAssertEqual(result, ["custom-tag:latest", "gpt-4", "gpt-3.5"])
    }

    func testMergePickerOptionsKeepsListUnchangedWhenSelectedPresent() {
        let result = OutputSettingsLogic.mergePickerOptions(
            available: ["gpt-4", "gpt-3.5"], selected: "gpt-4",
        )
        XCTAssertEqual(result, ["gpt-4", "gpt-3.5"])
    }

    func testMergePickerOptionsKeepsListUnchangedForEmptySelected() {
        let result = OutputSettingsLogic.mergePickerOptions(
            available: ["gpt-4"], selected: "",
        )
        XCTAssertEqual(result, ["gpt-4"])
    }

    func testMergePickerOptionsEmptyAvailableYieldsJustSelected() {
        let result = OutputSettingsLogic.mergePickerOptions(
            available: [], selected: "gpt-4",
        )
        XCTAssertEqual(result, ["gpt-4"])
    }

    func testMergePickerOptionsEmptyAvailableAndEmptySelectedYieldsEmpty() {
        let result = OutputSettingsLogic.mergePickerOptions(available: [], selected: "")
        XCTAssertTrue(result.isEmpty)
    }

    // MARK: - Render

    func testViewRendersWithDefaultSettings() throws {
        let settings = AppSettings(defaults: makeIsolatedDefaults())
        let view = OutputSettingsView(settings: settings)
        XCTAssertNoThrow(try view.inspect())
    }

    // MARK: - Helpers

    private func makeIsolatedDefaults() -> UserDefaults {
        let suite = "OutputSettingsViewTests-\(getpid())-\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else {
            fatalError("Could not create test UserDefaults suite")
        }
        return defaults
    }
}
