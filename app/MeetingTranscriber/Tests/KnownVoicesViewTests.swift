@testable import MeetingTranscriber
import ViewInspector
import XCTest

@MainActor
final class KnownVoicesViewTests: XCTestCase {
    // swiftlint:disable implicitly_unwrapped_optional
    private var tmpDir: URL!
    private var dbPath: URL!
    // swiftlint:enable implicitly_unwrapped_optional

    override func setUp() {
        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("KnownVoicesViewTests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        dbPath = tmpDir.appendingPathComponent("speakers.json")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tmpDir)
    }

    func testViewRendersWithEmptyDB() throws {
        let view = KnownVoicesView(matcher: SpeakerMatcher(dbPath: dbPath))
        XCTAssertNoThrow(try view.inspect())
    }

    func testViewRendersWithSpeakers() throws {
        let matcher = SpeakerMatcher(dbPath: dbPath)
        matcher.saveDB([
            StoredSpeaker(name: "Speaker A", embeddings: [[1, 0, 0]]),
            StoredSpeaker(name: "Speaker B", embeddings: [[0, 1, 0]]),
            StoredSpeaker(name: "Speaker C", embeddings: [[0, 0, 1]]),
        ])
        let view = KnownVoicesView(matcher: matcher)
        XCTAssertNoThrow(try view.inspect())
    }
}
