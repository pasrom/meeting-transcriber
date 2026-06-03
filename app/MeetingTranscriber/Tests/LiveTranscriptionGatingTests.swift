@testable import MeetingTranscriber
import XCTest

/// Boolean-gate tests for the live-transcription wiring:
///   * `TranscriptionEngineSetting.supportsLiveTranscription` — which engines
///     should expose the live toggle (Parakeet + WhisperKit yes, Qwen3 no
///     until its chunked API grows a streaming hook).
///   * `AppState.shouldShowLiveCaptions` — covers the no-watchLoop branches
///     of the AND-gate. Cases where `watchLoop?.state == .recording` would
///     need a real driven WatchLoop and are deferred to live-E2E.
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

    func testQwen3DoesNotSupportLive() {
        XCTAssertFalse(TranscriptionEngineSetting.qwen3.supportsLiveTranscription)
    }

    // MARK: - shouldShowLiveCaptions (watchLoop nil branch)

    func testShouldShowFalseWhenToggleOff() {
        settings.transcriptionEngine = .parakeet
        settings.liveTranscriptionEnabled = false
        let state = AppState(settings: settings)
        XCTAssertFalse(state.shouldShowLiveCaptions)
    }

    func testShouldShowFalseWhenToggleOnButEngineUnsupported() {
        guard #available(macOS 15, *) else {
            // Qwen3 is the only currently-unsupported engine, and it
            // requires macOS 15. Skip otherwise — coverage still hit via
            // the boolean enum tests above.
            return
        }
        settings.transcriptionEngine = .qwen3
        settings.liveTranscriptionEnabled = true
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
}
