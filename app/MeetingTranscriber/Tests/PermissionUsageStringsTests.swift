import XCTest

/// The usage strings in `Info.plist` are what macOS shows when it asks for a
/// grant. They must describe what the grant is used for today: Accessibility
/// only reads Teams participant names (`ParticipantReader`), and meeting
/// detection needs no Screen Recording (`PowerAssertionDetector` and
/// `MicInputDetector` read no window titles), which only sharpens the meeting
/// title and is a fallback grant for the app-audio tap.
final class PermissionUsageStringsTests: XCTestCase {
    private func usageString(_ key: String) throws -> String {
        let plist = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/Info.plist")
        let data = try Data(contentsOf: plist)
        let dict = try XCTUnwrap(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        return try XCTUnwrap(dict[key] as? String, key)
    }

    func testAccessibilityStringNamesOnlyTheParticipantReading() throws {
        let text = try usageString("NSAccessibilityUsageDescription").lowercased()
        XCTAssertTrue(text.contains("participant"), text)
        XCTAssertFalse(text.contains("mute"), "there is no mute detection: \(text)")
    }

    func testScreenRecordingStringDoesNotClaimMeetingDetection() throws {
        let text = try usageString("NSScreenCaptureUsageDescription").lowercased()
        XCTAssertFalse(text.contains("detect"), "detection reads no window titles: \(text)")
        XCTAssertTrue(text.contains("audio"), "the grant is a fallback for the app-audio tap: \(text)")
    }
}
