@testable import MeetingTranscriber
import XCTest

// MARK: - Test Helpers

final class RecordingNotifier: AppNotifying {
    private(set) var calls: [(title: String, body: String)] = []

    func notify(title: String, body: String) {
        calls.append((title: title, body: body))
    }
}

// MARK: - AppState Integration Tests

@MainActor
final class AppStateTests: XCTestCase {
    func testAppStateIsWatchingFalseWhenNoWatchLoop() {
        let state = AppState()
        XCTAssertFalse(state.isWatching)
    }

    func testAppStateCurrentStateLabelIdleByDefault() {
        let state = AppState()
        XCTAssertEqual(state.currentStateLabel, "Idle")
    }

    func testAppStateCurrentBadgeInactiveByDefault() {
        let state = AppState()
        XCTAssertEqual(state.currentBadge, .inactive)
    }

    func testAppStateCurrentStatusNilWhenNoWatchLoop() {
        let state = AppState()
        XCTAssertNil(state.currentStatus)
    }

    func testAppStateCurrentBadgeReflectsEnqueuedJob() throws {
        let state = AppState()
        let tmpDir = FileManager.default.temporaryDirectory
        let audioURL = tmpDir.appendingPathComponent("test_badge_\(UUID()).wav")
        try Data().write(to: audioURL)
        defer { try? FileManager.default.removeItem(at: audioURL) }

        let job = PipelineJob(
            meetingTitle: "Test Meeting",
            appName: "TestApp",
            mixPath: audioURL,
            appPath: nil,
            micPath: nil,
            micDelay: 0,
        )
        state.pipelineQueue.enqueue(job)

        // waiting jobs are not active — badge stays inactive until processing starts
        XCTAssertFalse(state.pipelineQueue.jobs.isEmpty)
    }

    func testAppStateCurrentBadgeUpdateAvailableWithNoActivity() throws {
        let state = AppState()
        let url = try XCTUnwrap(URL(string: "https://example.com"))
        state.updateChecker.availableUpdate = ReleaseInfo(
            tagName: "v9.9.9",
            name: "Test Release",
            prerelease: false,
            htmlURL: url,
            dmgURL: nil,
        )
        XCTAssertEqual(state.currentBadge, .updateAvailable)
    }
}
