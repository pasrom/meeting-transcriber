@testable import MeetingTranscriber
import XCTest

/// Per-process browser identity: every Chromium fork is carried as itself
/// rather than aliased into one shared browser identity. The forks used here
/// are all on the current allowlist on purpose, so these tests pin the
/// identity change alone and stay independent of process-open matching.
final class PowerAssertionDetectorIdentityTests: XCTestCase {
    // MARK: - Identity key

    func testSharedPatternIdentityKeyIsTheAppNameForAnyProcess() {
        // A native pattern is unaffected: whichever of its process names
        // asserted, the identity stays the one app.
        let teams = PowerAssertionDetector.defaultPatterns.first { $0.appName == "Microsoft Teams" }
        XCTAssertEqual(teams?.identity, .shared)
        XCTAssertEqual(teams?.identityKey(processName: "MSTeams"), "Microsoft Teams")
        XCTAssertEqual(teams?.identityKey(processName: "Microsoft Teams"), "Microsoft Teams")
    }

    func testPerProcessPatternIdentityKeyIsTheConcreteProcess() {
        // The browser pattern carries each fork as itself, which is what gives
        // every browser its own confirmation count, cooldown and tap target.
        let browser = PowerAssertionDetector.defaultPatterns
            .first { $0.appName == AppMeetingPattern.browserMeetings.appName }
        XCTAssertEqual(browser?.identity, .perProcess)
        XCTAssertEqual(browser?.identityKey(processName: "Brave Browser"), "Brave Browser")
        XCTAssertEqual(browser?.identityKey(processName: "Microsoft Edge"), "Microsoft Edge")
    }

    // MARK: - Synthesised identity

    func testPerProcessIdentityKeepsTheConsentRequirement() throws {
        // The trap this test exists for: with per-process identity,
        // `forAppName("Brave Browser")` no longer resolves, so the identity is
        // synthesised. The synthesis default for `requiresRecordingConsent` is
        // false, which would auto-record a browser call with no prompt.
        let browser = try XCTUnwrap(
            PowerAssertionDetector.defaultPatterns
                .first { $0.appName == AppMeetingPattern.browserMeetings.appName },
        )
        let identity = PowerAssertionDetector.meetingIdentity(
            pattern: browser, processName: "Brave Browser",
        )
        XCTAssertEqual(identity.appName, "Brave Browser")
        XCTAssertEqual(identity.ownerNames, ["Brave Browser"])
        XCTAssertTrue(identity.requiresRecordingConsent)
        // No title patterns: a browser window title reflects the active tab.
        XCTAssertTrue(identity.meetingPatterns.isEmpty)
    }

    func testSharedIdentityStillResolvesTheKnownAppPattern() throws {
        let teams = try XCTUnwrap(
            PowerAssertionDetector.defaultPatterns.first { $0.appName == "Microsoft Teams" },
        )
        let identity = PowerAssertionDetector.meetingIdentity(
            pattern: teams, processName: "MSTeams",
        )
        XCTAssertEqual(identity.appName, "Microsoft Teams")
    }

    func testAnUnresolvableCategoryStillRequiresConsent() {
        // The safety net I called the most dangerous line in this change, and
        // then only tested from the safe side. The category `appName` is looked
        // up in `AppMeetingPattern`; a typo or a rename applied on one side only
        // makes that nil, and the initializer defaults
        // `requiresRecordingConsent` to false, which means auto-record with no
        // prompt. The init drift guard deliberately skips `.perProcess`
        // patterns, so this branch is the only thing between a rename and
        // silent recording.
        let broken = PowerAssertionDetector.AssertionPattern(
            appName: "No Such Category",
            processNames: [],
            keywords: ["webrtc"],
            identity: .perProcess,
        )
        XCTAssertNil(AppMeetingPattern.forAppName(broken.appName), "precondition: must not resolve")
        let identity = PowerAssertionDetector.meetingIdentity(
            pattern: broken, processName: PowerAssertionFixture.unknownBrowser,
        )
        XCTAssertEqual(identity.appName, PowerAssertionFixture.unknownBrowser)
        XCTAssertTrue(
            identity.requiresRecordingConsent,
            "an unresolvable category must fail towards asking, never towards recording",
        )
    }

    // MARK: - Malformed assertion data

    func testAnAssertionMissingItsFieldsIsIgnored() throws {
        // IOKit hands us untyped dictionaries. A missing "Process Name" or
        // "AssertName" must be skipped rather than crash or match on nothing.
        let detector = PowerAssertionFixture.browserDetector()
        detector.assertionProvider = {
            [
                1: [["AssertName": PowerAssertionFixture.webRTC]],
                2: [["Process Name": "Brave Browser"]],
                3: [[:]],
            ]
        }
        XCTAssertNil(detector.checkOnce(), "incomplete assertions must not confirm a meeting")

        // Same guard on the liveness path: a detected meeting must not be kept
        // alive by an assertion we cannot even read.
        detector.assertionProvider = {
            PowerAssertionFixture.assertions((7, "Brave Browser", PowerAssertionFixture.webRTC))
        }
        let meeting = try XCTUnwrap(detector.checkOnce())
        detector.assertionProvider = { [1: [["AssertName": PowerAssertionFixture.webRTC]]] }
        XCTAssertFalse(detector.isMeetingActive(meeting))
    }

    // MARK: - Detector behaviour

    func testConfirmationCountsAreCountedPerBrowser() {
        // Poll 1: only Brave. Poll 2: Brave and Edge. With a shared key, poll 2
        // would be the shared key's second hit and `firstMatch` could be either
        // browser; per-process, only Brave has reached two polls.
        let detector = PowerAssertionFixture.browserDetector(confirmationCount: 2)
        detector.assertionProvider = { PowerAssertionFixture.assertions((7, "Brave Browser", PowerAssertionFixture.webRTC)) }
        XCTAssertNil(detector.checkOnce())

        detector.assertionProvider = {
            PowerAssertionFixture.assertions((7, "Brave Browser", PowerAssertionFixture.webRTC), (9, "Microsoft Edge", PowerAssertionFixture.webRTC))
        }
        let meeting = detector.checkOnce()
        XCTAssertEqual(meeting?.pattern.appName, "Brave Browser")
        XCTAssertEqual(meeting?.ownerName, "Brave Browser")
        XCTAssertEqual(meeting?.windowPID, 7)
    }

    func testLivenessFollowsTheBrowserThatHeldTheMeeting() throws {
        let detector = PowerAssertionFixture.browserDetector()
        detector.assertionProvider = { PowerAssertionFixture.assertions((7, "Brave Browser", PowerAssertionFixture.webRTC)) }
        let meeting = try XCTUnwrap(detector.checkOnce())

        // Another fork's call must not keep this recording alive: that is what
        // ran a finished meeting to the four hour cap.
        detector.assertionProvider = { PowerAssertionFixture.assertions((9, "Microsoft Edge", PowerAssertionFixture.webRTC)) }
        XCTAssertFalse(detector.isMeetingActive(meeting))

        // Its own call must, or every browser recording would stop at the grace
        // period instead.
        detector.assertionProvider = { PowerAssertionFixture.assertions((7, "Brave Browser", PowerAssertionFixture.webRTC)) }
        XCTAssertTrue(detector.isMeetingActive(meeting))
    }

    func testANativeCallDoesNotKeepAnotherAppsMeetingAlive() throws {
        // Liveness across pattern boundaries, which nothing covered: a browser-
        // only detector cannot see it, because it needs two different patterns.
        // The regression it guards against was a comparison that collapsed to
        // `appName == appName` for shared patterns and so matched everything,
        // leaving isMeetingActive with no filter at all.
        let detector = PowerAssertionDetector(
            patterns: PowerAssertionDetector.patterns(
                watching: ["Microsoft Teams", "Zoom", AppMeetingPattern.browserMeetings.appName],
            ),
            confirmationCount: 1,
        )
        detector.windowListProvider = { [] }
        detector.assertionProvider = { PowerAssertionFixture.assertions((3, "zoom.us", "Zoom call")) }
        let zoom = try XCTUnwrap(detector.checkOnce())
        XCTAssertEqual(zoom.pattern.appName, "Zoom")

        // Zoom hung up; only Teams is in a call now. The Zoom meeting is over.
        detector.assertionProvider = {
            PowerAssertionFixture.assertions((4, "MSTeams", "call in progress"))
        }
        XCTAssertFalse(
            detector.isMeetingActive(zoom),
            "another app's call must not keep a finished meeting recording",
        )

        // And a browser call must not either.
        detector.assertionProvider = {
            PowerAssertionFixture.assertions((5, "Brave Browser", PowerAssertionFixture.webRTC))
        }
        XCTAssertFalse(detector.isMeetingActive(zoom))

        // Control: its own assertion still does.
        detector.assertionProvider = { PowerAssertionFixture.assertions((3, "zoom.us", "Zoom call")) }
        XCTAssertTrue(detector.isMeetingActive(zoom))
    }

    func testADeniedIdentityNeverConfirms() {
        // A denial does not expire, so letting it confirm and be skipped later
        // meant re-confirming forever, and every skip called reset, which wipes
        // the confirmation counters of every other app.
        let detector = PowerAssertionFixture.browserDetector()
        detector.isIdentityDenied = { $0 == "Fjordfox" }
        detector.assertionProvider = {
            PowerAssertionFixture.assertions((7, "Fjordfox", PowerAssertionFixture.webRTC))
        }
        XCTAssertNil(detector.checkOnce())

        // Control: an identity that was not denied still confirms.
        detector.assertionProvider = {
            PowerAssertionFixture.assertions((8, "Brave Browser", PowerAssertionFixture.webRTC))
        }
        XCTAssertEqual(detector.checkOnce()?.pattern.appName, "Brave Browser")
    }

    func testTitleComesFromTheDetectedBrowserOnly() {
        // With one shared identity the title matcher accepted any family
        // browser's window, leaking an unrelated tab title into the protocol
        // filename and the model prompt.
        let detector = PowerAssertionFixture.browserDetector()
        detector.assertionProvider = { PowerAssertionFixture.assertions((7, "Brave Browser", PowerAssertionFixture.webRTC)) }
        detector.windowListProvider = {
            [
                ["kCGWindowOwnerName": "Microsoft Edge", "kCGWindowName": "Private Banking"],
                ["kCGWindowOwnerName": "Brave Browser", "kCGWindowName": "Weekly Sync"],
            ]
        }
        XCTAssertEqual(detector.checkOnce()?.windowTitle, "Weekly Sync")
    }
}
