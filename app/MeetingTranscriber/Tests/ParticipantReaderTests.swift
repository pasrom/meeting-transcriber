@testable import MeetingTranscriber
import XCTest

final class ParticipantReaderTests: XCTestCase {
    // MARK: - Basic Filtering

    func testFilterValidNames() {
        let input = ["Alice Smith", "Bob Jones", "Carol Lee"]
        let result = ParticipantReader.filterParticipantNames(input)
        XCTAssertEqual(result, ["Alice Smith", "Bob Jones", "Carol Lee"])
    }

    func testFilterRemovesEmptyAndShort() {
        let input = ["", " ", "A", "Alice"]
        let result = ParticipantReader.filterParticipantNames(input)
        XCTAssertEqual(result, ["Alice"])
    }

    func testFilterRemovesDuplicates() {
        let input = ["Alice", "Alice", "Bob"]
        let result = ParticipantReader.filterParticipantNames(input)
        XCTAssertEqual(result, ["Alice", "Bob"])
    }

    func testFilterRemovesYouSuffix() {
        let input = ["Alice Smith (you)"]
        let result = ParticipantReader.filterParticipantNames(input)
        XCTAssertEqual(result, ["Alice Smith"])
    }

    // MARK: - UI Label Filtering

    func testFilterRemovesKnownUILabels() {
        let input = ["Mute", "participants", "Alice", "Share"]
        let result = ParticipantReader.filterParticipantNames(input)
        XCTAssertEqual(result, ["Alice"])
    }

    func testFilterRemovesTimestamps() {
        let input = ["10:30", "Alice", "2:45"]
        let result = ParticipantReader.filterParticipantNames(input)
        XCTAssertEqual(result, ["Alice"])
    }

    // MARK: - Screen Share Artifact Filtering

    func testFilterRemovesNavigationBreadcrumbs() {
        let input = [
            "Go to App → Settings → Connectors/Integrations → Connection:",
            "Alice Smith",
        ]
        let result = ParticipantReader.filterParticipantNames(input)
        XCTAssertEqual(result, ["Alice Smith"])
    }

    func testFilterRemovesArrowSeparators() {
        let input = ["Home → Settings → Profile", "Bob"]
        let result = ParticipantReader.filterParticipantNames(input)
        XCTAssertEqual(result, ["Bob"])
    }

    func testFilterRemovesChevronSeparators() {
        let input = ["Home › Settings › Profile", "Carol"]
        let result = ParticipantReader.filterParticipantNames(input)
        XCTAssertEqual(result, ["Carol"])
    }

    func testFilterRemovesColonSuffix() {
        let input = ["Integration-Page::", "Connection:", "Alice"]
        let result = ParticipantReader.filterParticipantNames(input)
        XCTAssertEqual(result, ["Alice"])
    }

    func testFilterRemovesURLLikeStrings() {
        let input = ["example.ai", "example.com", "example.io", "Alice"]
        let result = ParticipantReader.filterParticipantNames(input)
        XCTAssertEqual(result, ["Alice"])
    }

    func testFilterRemovesHTTPUrls() {
        let input = ["https://example.com", "http://localhost", "Alice"]
        let result = ParticipantReader.filterParticipantNames(input)
        XCTAssertEqual(result, ["Alice"])
    }

    func testFilterRemovesLongStrings() {
        let longText = String(repeating: "a", count: 61)
        let input = [longText, "Alice"]
        let result = ParticipantReader.filterParticipantNames(input)
        XCTAssertEqual(result, ["Alice"])
    }

    func testFilterRemovesPathLikeStrings() {
        let input = ["Connectors/Integrations/Settings", "Alice"]
        let result = ParticipantReader.filterParticipantNames(input)
        XCTAssertEqual(result, ["Alice"])
    }

    func testFilterKeepsNameWithSingleSlash() {
        // Some corporate names might have a single slash
        let input = ["Team A/B", "Alice"]
        let result = ParticipantReader.filterParticipantNames(input)
        XCTAssertEqual(result, ["Team A/B", "Alice"])
    }

    // MARK: - German Labels

    func testFiltersGermanLabels() {
        let result = ParticipantReader.filterParticipantNames(["Stummschalten", "Alice"])
        XCTAssertEqual(result, ["Stummschalten", "Alice"])
    }

    func testRealWorldTeamsRoster() {
        let texts = [
            "People", "In this meeting", "4",
            "Alice Johnson (you)", "Bob Smith", "Charlie Brown", "Diana Prince",
            "Mute", "Camera", "Raise hand",
        ]
        let result = ParticipantReader.filterParticipantNames(texts)
        XCTAssertEqual(result, ["Alice Johnson", "Bob Smith", "Charlie Brown", "Diana Prince"])
    }

    // MARK: - Realistic Screen Share Scenario

    func testFilterRealisticScreenShareArtifacts() {
        let input = [
            "Alice Smith",
            "Bob Jones",
            "Go to App → Settings → Connectors/Integrations → Connection:",
            "Integration-Page::",
            "https://id.example.com/manage-profile",
        ]
        let result = ParticipantReader.filterParticipantNames(input)
        XCTAssertEqual(result, ["Alice Smith", "Bob Jones"])
    }
}
