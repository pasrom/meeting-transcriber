#if !APPSTORE
    @testable import MeetingTranscriber
    import UserNotifications
    import XCTest

    /// Covers the permission-health surface exposed in the RPC `/state` snapshot
    /// (issue #446 follow-up): the `PermissionStatus` → wire-string mapping, the
    /// pre-check `.unknown` placeholder, and that it serialises into the snapshot JSON.
    final class RPCPermissionHealthTests: XCTestCase {
        // MARK: - PermissionStatus.rpcValue

        func testRPCValueMapsEveryStatus() {
            XCTAssertEqual(PermissionStatus.healthy.rpcValue, "healthy")
            XCTAssertEqual(PermissionStatus.denied.rpcValue, "denied")
            XCTAssertEqual(PermissionStatus.broken.rpcValue, "broken")
            XCTAssertEqual(PermissionStatus.notDetermined.rpcValue, "notDetermined")
        }

        /// Sibling table for the notification status. These strings are a wire
        /// contract that `scripts/e2e-browser.sh` asserts on, and they are
        /// hand-written precisely so they cannot shift with Apple's enum.
        func testNotificationAuthorizationRPCValues() {
            XCTAssertEqual(UNAuthorizationStatus.authorized.rpcValue, "authorized")
            XCTAssertEqual(UNAuthorizationStatus.denied.rpcValue, "denied")
            XCTAssertEqual(UNAuthorizationStatus.notDetermined.rpcValue, "notDetermined")
            XCTAssertEqual(UNAuthorizationStatus.provisional.rpcValue, "provisional")
        }

        // MARK: - PermissionHealth placeholder

        func testUnknownPlaceholderIsNotHealthy() {
            let unknown = RPCStateSnapshot.PermissionHealth.unknown
            XCTAssertEqual(unknown.screenRecording, "unknown")
            XCTAssertEqual(unknown.microphone, "unknown")
            XCTAssertEqual(unknown.accessibility, "unknown")
            XCTAssertEqual(unknown.notifications, "unknown")
            XCTAssertEqual(unknown.notificationsAlertStyle, "unknown")
            XCTAssertEqual(unknown.notificationsTimeSensitive, "unknown")
            // "not yet checked" must not read as healthy.
            XCTAssertFalse(unknown.isHealthy)
        }

        // MARK: - Serialisation

        func testPermissionHealthSerialisesIntoSnapshotJSON() throws {
            let snapshot = RPCStateSnapshot(
                pipeline: .init(
                    isProcessing: false,
                    activeJobCount: 0,
                    waitingJobCount: 0,
                    pendingNamingJobCount: 0,
                ),
                speakerDB: .init(count: 0, recentNames: [], knownSpeakerNames: []),
                pendingNamingJobs: [],
                permissionHealth: .init(
                    screenRecording: "healthy",
                    microphone: "broken",
                    accessibility: "denied",
                    isHealthy: false,
                    notifications: "denied",
                    notificationsAlertStyle: "none",
                    notificationsTimeSensitive: "disabled",
                    notificationsScheduledDelivery: "enabled",
                ),
            )
            let json = try XCTUnwrap(String(data: snapshot.jsonData(), encoding: .utf8))
            // jsonData() is pretty-printed with sorted keys → `"key" : "value"`.
            XCTAssertTrue(json.contains("\"permissionHealth\""), json)
            XCTAssertTrue(json.contains("\"screenRecording\" : \"healthy\""), json)
            XCTAssertTrue(json.contains("\"microphone\" : \"broken\""), json)
            XCTAssertTrue(json.contains("\"accessibility\" : \"denied\""), json)
            // Notification authorisation rides in the same struct so the browser
            // e2e lane can prove the consent prompt is deliverable on the runner.
            // Its RPC path answers consent directly, which works whether or not a
            // notification was ever shown, so this is the lane's only way to see
            // a runner where the feature would be dead for a real user.
            XCTAssertTrue(json.contains("\"notifications\" : \"denied\""), json)
            // And the presentation settings alongside it: authorisation alone
            // cannot tell an audible prompt from one that is never shown, which
            // is the state the browser lane has to be able to refuse to run in.
            XCTAssertTrue(json.contains("\"notificationsAlertStyle\" : \"none\""), json)
            XCTAssertTrue(json.contains("\"notificationsTimeSensitive\" : \"disabled\""), json)
            XCTAssertTrue(json.contains("\"notificationsScheduledDelivery\" : \"enabled\""), json)
        }

        /// Wire strings for the presentation settings, pinned for the same
        /// reason as the authorisation table: `scripts/e2e-browser.sh` greps for
        /// them, and Apple renumbering an enum must not silently change them.
        func testNotificationPresentationRPCValues() {
            XCTAssertEqual(UNNotificationSetting.enabled.rpcValue, "enabled")
            XCTAssertEqual(UNNotificationSetting.disabled.rpcValue, "disabled")
            XCTAssertEqual(UNNotificationSetting.notSupported.rpcValue, "notSupported")
            XCTAssertEqual(UNAlertStyle.none.rpcValue, "none")
            XCTAssertEqual(UNAlertStyle.banner.rpcValue, "banner")
            XCTAssertEqual(UNAlertStyle.alert.rpcValue, "alert")
        }
    }
#endif
