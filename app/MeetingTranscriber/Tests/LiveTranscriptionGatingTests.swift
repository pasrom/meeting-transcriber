@testable import MeetingTranscriber
import XCTest

/// Boolean-gate tests for the live-transcription wiring:
///   * `TranscriptionEngineSetting.supportsLiveTranscription` — which engines
///     should expose the live toggle (Parakeet + WhisperKit yes).
///   * `AppState.shouldShowLiveCaptions` — covers the no-watchLoop branches
///     of the AND-gate, plus the recording + overlay path via a driven
///     `WatchLoop` (`ManualRecordingTests.makeLoop` / `makeTestWatchLoop`).
@MainActor
final class LiveTranscriptionGatingTests: XCTestCase {
    // swiftlint:disable:next implicitly_unwrapped_optional
    private var defaults: UserDefaults!
    // swiftlint:disable:next implicitly_unwrapped_optional
    private var settings: AppSettings!
    // swiftlint:disable:next implicitly_unwrapped_optional
    private var testSuiteName: String!

    override func setUp() async throws {
        try await super.setUp()
        testSuiteName = "LiveTranscriptionGatingTests-\(getpid())-\(UUID().uuidString)"
        guard let suite = UserDefaults(suiteName: testSuiteName) else {
            XCTFail("Could not create test UserDefaults suite")
            return
        }
        defaults = suite
        settings = AppSettings(defaults: defaults)
    }

    override func tearDown() async throws {
        settings = nil
        defaults.removePersistentDomain(forName: testSuiteName)
        defaults = nil
        testSuiteName = nil
        try await super.tearDown()
    }

    // MARK: - supportsLiveTranscription

    func testParakeetSupportsLive() {
        XCTAssertTrue(TranscriptionEngineSetting.parakeet.supportsLiveTranscription)
    }

    func testWhisperKitSupportsLive() {
        XCTAssertTrue(TranscriptionEngineSetting.whisperKit.supportsLiveTranscription)
    }

    // MARK: - shouldShowLiveCaptions (watchLoop nil branch)

    func testShouldShowFalseWhenToggleOff() {
        settings.transcriptionEngine = .parakeet
        settings.liveTranscriptionEnabled = false
        let state = AppState(settings: settings)
        XCTAssertFalse(state.shouldShowLiveCaptions)
    }

    func testShouldShowFalseWhenToggleOnSupportedEngineButNoActiveWatchLoop() {
        settings.transcriptionEngine = .parakeet
        settings.liveTranscriptionEnabled = true
        let state = AppState(settings: settings)
        // No watch loop has been started → recording state is unreachable
        XCTAssertNil(state.watching.watchLoop)
        XCTAssertFalse(state.shouldShowLiveCaptions)
    }

    func testShouldShowFalseForWhisperKitWhenNoActiveWatchLoop() {
        settings.transcriptionEngine = .whisperKit
        settings.liveTranscriptionEnabled = true
        let state = AppState(settings: settings)
        XCTAssertNil(state.watching.watchLoop)
        XCTAssertFalse(state.shouldShowLiveCaptions)
    }

    // MARK: - shouldShowLiveCaptions (recording + overlay)

    /// Pins `AppState.shouldShowLiveCaptions` reading `settings.liveCaptionsOverlayEnabled`
    /// through a driven watch loop. Hardcoding `overlayEnabled: true` in
    /// `shouldShowLiveCaptions` must turn the overlay-off assertion red.
    func testShouldShowFollowsOverlayToggleWhileRecording() async throws {
        settings.transcriptionEngine = .parakeet
        settings.parakeetLanguage = "en"
        settings.liveTranscriptionEnabled = true
        settings.liveCaptionsOverlayEnabled = true
        let state = AppState(settings: settings)
        let (loop, _) = makeTestWatchLoop()
        state.watching.watchLoop = loop
        try await loop.startManualRecording(pid: 1234, appName: "Chrome", title: "Meeting")
        defer { loop.stop() }
        XCTAssertEqual(loop.state, .recording)
        XCTAssertTrue(
            state.shouldShowLiveCaptions,
            "overlay on + recording + live on → captions bar should show",
        )

        settings.liveCaptionsOverlayEnabled = false
        XCTAssertFalse(
            state.shouldShowLiveCaptions,
            "overlay off must hide the captions bar while transcription still runs",
        )

        settings.liveCaptionsOverlayEnabled = true
        XCTAssertTrue(
            state.shouldShowLiveCaptions,
            "turning the overlay back on must show the captions bar again",
        )
    }
}
