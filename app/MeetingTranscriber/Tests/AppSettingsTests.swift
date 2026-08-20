import Foundation
@testable import MeetingTranscriber
import XCTest

final class AppSettingsTests: XCTestCase {
    // swiftlint:disable:next implicitly_unwrapped_optional
    private var settings: AppSettings!
    // swiftlint:disable:next implicitly_unwrapped_optional
    private var defaults: UserDefaults!
    // swiftlint:disable:next implicitly_unwrapped_optional
    private var testSuiteName: String!
    // swiftlint:disable:next implicitly_unwrapped_optional
    private var apiKeyAccount: String!

    /// Each test gets its own volatile `UserDefaults(suiteName:)` so
    /// `swift test --parallel` doesn't race on the shared on-disk plist.
    /// AppSettings receives the suite via constructor injection.
    ///
    /// The Keychain account backing `openAIAPIKey` is injected the same way,
    /// for a stronger reason. Keychain state is per-user, not per-process, and
    /// the production account holds the API key the user actually configured
    /// in the app — so driving it from a test would overwrite and then delete
    /// a real credential. It is also owned by the app's code signature, so the
    /// test binary touching it raises a Keychain authorization prompt that
    /// blocks `swift test` indefinitely. A unique account per test avoids both,
    /// and removes the sibling-process race under `--parallel`.
    override func setUp() {
        super.setUp()
        testSuiteName = "AppSettingsTests-\(getpid())-\(UUID().uuidString)"
        apiKeyAccount = "AppSettingsTests-openAIAPIKey-\(getpid())-\(UUID().uuidString)"
        guard let suite = UserDefaults(suiteName: testSuiteName) else {
            XCTFail("Could not create test UserDefaults suite")
            return
        }
        defaults = suite
        settings = AppSettings(defaults: defaults, apiKeyAccount: apiKeyAccount)
    }

    override func tearDown() {
        settings = nil
        defaults.removePersistentDomain(forName: testSuiteName)
        defaults = nil
        testSuiteName = nil
        KeychainHelper.delete(key: apiKeyAccount)
        apiKeyAccount = nil
        super.tearDown()
    }

    // MARK: - Defaults

    func testDefaultValues() {
        XCTAssertEqual(settings.pollInterval, 3.0)
        XCTAssertEqual(settings.endGrace, 15.0)
        XCTAssertEqual(settings.numSpeakers, 0)
        XCTAssertTrue(settings.watchTeams)
        XCTAssertTrue(settings.watchZoom)
        XCTAssertTrue(settings.watchWebex)
        XCTAssertFalse(settings.noMic)
        XCTAssertEqual(settings.micName, "Me")
        XCTAssertTrue(settings.diarize)
        XCTAssertEqual(settings.whisperKitModel, "openai_whisper-large-v3-v20240930_turbo")
        XCTAssertTrue(settings.perChannelIndicatorEnabled)
        XCTAssertEqual(settings.asymmetricSilenceWarningSeconds, 90.0)
        XCTAssertFalse(settings.liveTranscriptionEnabled)
    }

    func test_activeEngineLanguageOrNil_followsWhisperKitLanguage() {
        settings.transcriptionEngine = .whisperKit
        settings.whisperLanguage = "de"
        XCTAssertEqual(settings.activeEngineLanguageOrNil, "de")
        settings.whisperLanguage = ""
        XCTAssertNil(settings.activeEngineLanguageOrNil, "empty language = auto-detect → nil")
    }

    func test_activeEngineLanguageOrNil_followsParakeetLanguageWhenParakeetActive() {
        settings.transcriptionEngine = .parakeet
        settings.parakeetLanguage = "en"
        XCTAssertEqual(settings.activeEngineLanguageOrNil, "en")
    }

    // MARK: - Clamping

    func testPollIntervalClampedToMinimum() {
        settings.pollInterval = 0.1
        XCTAssertEqual(settings.pollInterval, 1.0)
    }

    func testPollIntervalAcceptsValidValue() {
        settings.pollInterval = 5.0
        XCTAssertEqual(settings.pollInterval, 5.0)
    }

    func testPollIntervalBoundaryValue() {
        settings.pollInterval = 1.0
        XCTAssertEqual(settings.pollInterval, 1.0)
    }

    func testEndGraceClampedToMinimum() {
        settings.endGrace = 0.5
        XCTAssertEqual(settings.endGrace, 1.0)
    }

    func testEndGraceAcceptsValidValue() {
        settings.endGrace = 30.0
        XCTAssertEqual(settings.endGrace, 30.0)
    }

    func testEndGraceBoundaryValue() {
        settings.endGrace = 5.0
        XCTAssertEqual(settings.endGrace, 5.0)
    }

    func testNumSpeakersClampedToMinimum() {
        settings.numSpeakers = -1
        XCTAssertEqual(settings.numSpeakers, 0)
    }

    func testAsymmetricSilenceWarningSecondsClampedToMinimum() {
        settings.asymmetricSilenceWarningSeconds = 10
        XCTAssertEqual(settings.asymmetricSilenceWarningSeconds, 30)
    }

    func testAsymmetricSilenceWarningSecondsClampedToMaximum() {
        settings.asymmetricSilenceWarningSeconds = 600
        XCTAssertEqual(settings.asymmetricSilenceWarningSeconds, 300)
    }

    func testAsymmetricSilenceWarningSecondsAcceptsValidValue() {
        settings.asymmetricSilenceWarningSeconds = 120
        XCTAssertEqual(settings.asymmetricSilenceWarningSeconds, 120)
    }

    func testNumSpeakersClampedToMinimumZero() {
        settings.numSpeakers = 0
        XCTAssertEqual(settings.numSpeakers, 0)
    }

    func testNumSpeakersAcceptsValidValue() {
        settings.numSpeakers = 5
        XCTAssertEqual(settings.numSpeakers, 5)
    }

    // MARK: - UserDefaults persistence

    func testPollIntervalSavedToDefaults() {
        settings.pollInterval = 7.0
        XCTAssertEqual(defaults.double(forKey: "pollInterval"), 7.0)
    }

    func testClampedValueSavedToDefaults() {
        settings.pollInterval = 0.5
        XCTAssertEqual(defaults.double(forKey: "pollInterval"), 1.0)
    }

    // MARK: - Output Directory (issue #626)

    /// The Settings UI derives the folder it shows from `effectiveOutputDir`.
    /// While `customOutputDirBookmark` was a computed passthrough to
    /// `UserDefaults`, `@Observable` had no stored property to track, so
    /// choosing a new folder never invalidated the view and the label kept
    /// showing the previous path until the app was relaunched.
    func testCustomOutputDirBookmarkNotifiesObservers() throws {
        let dir = try makeTempDirectory(prefix: "AppSettingsOutputDir")
        let changed = expectation(description: "effectiveOutputDir observers notified")
        withObservationTracking {
            _ = settings.effectiveOutputDir
        } onChange: {
            changed.fulfill()
        }

        settings.setCustomOutputDir(dir)

        wait(for: [changed], timeout: 1.0)
        // The notification is only half of it: assert the derived value the UI
        // actually renders followed too. A plain `dir.bookmarkData()` would not
        // resolve under `.withSecurityScope`, leaving this on the default path
        // and the test green either way — hence the real API.
        XCTAssertEqual(
            settings.effectiveOutputDir.resolvingSymlinksInPath().path,
            dir.resolvingSymlinksInPath().path,
        )
    }

    /// The counterpart: reading the derived value must not write to the observed
    /// bookmark. `body` reads `effectiveOutputDir`, so a mutation on this path
    /// would invalidate the view during its own update.
    func testReadingEffectiveOutputDirDoesNotMutateTheBookmark() throws {
        let dir = try makeTempDirectory(prefix: "AppSettingsOutputDir")
        settings.setCustomOutputDir(dir)
        let bookmark = try XCTUnwrap(settings.customOutputDirBookmark)

        withObservationTracking {
            _ = settings.effectiveOutputDir
        } onChange: {
            XCTFail("reading effectiveOutputDir must not mutate observed state")
        }
        _ = settings.effectiveOutputDir

        XCTAssertEqual(settings.customOutputDirBookmark, bookmark)
    }

    /// Repair is a no-op while the bookmark still resolves. The stale branch
    /// itself needs a folder moved out from under a live bookmark, which isn't
    /// reproducible in-process — it stays covered by the launch call site only.
    func testRepairLeavesAResolvableBookmarkAlone() throws {
        let dir = try makeTempDirectory(prefix: "AppSettingsOutputDir")
        settings.setCustomOutputDir(dir)
        let bookmark = try XCTUnwrap(settings.customOutputDirBookmark)

        settings.repairStaleCustomOutputDirBookmark()

        XCTAssertEqual(settings.customOutputDirBookmark, bookmark)
    }

    func testClearCustomOutputDirNotifiesObservers() throws {
        let dir = try makeTempDirectory(prefix: "AppSettingsOutputDir")
        settings.setCustomOutputDir(dir)

        let changed = expectation(description: "reset notifies observers")
        withObservationTracking {
            _ = settings.effectiveOutputDir
        } onChange: {
            changed.fulfill()
        }

        settings.clearCustomOutputDir()

        wait(for: [changed], timeout: 1.0)
        XCTAssertEqual(settings.effectiveOutputDir, AppPaths.downloadsProtocolsDir)
    }

    /// Guards the other half of the move to a stored property: the bookmark
    /// must still round-trip through `UserDefaults` across launches.
    func testCustomOutputDirBookmarkPersistsAcrossInstances() throws {
        let dir = try makeTempDirectory(prefix: "AppSettingsOutputDir")
        settings.setCustomOutputDir(dir)
        let bookmark = try XCTUnwrap(settings.customOutputDirBookmark)
        XCTAssertEqual(defaults.data(forKey: "customOutputDirBookmark"), bookmark)

        let reloaded = AppSettings(defaults: defaults, apiKeyAccount: apiKeyAccount)
        XCTAssertEqual(reloaded.customOutputDirBookmark, bookmark)
        XCTAssertEqual(
            reloaded.effectiveOutputDir.resolvingSymlinksInPath().path,
            dir.resolvingSymlinksInPath().path,
        )

        reloaded.clearCustomOutputDir()
        XCTAssertNil(defaults.data(forKey: "customOutputDirBookmark"))
    }

    // MARK: - watchApps

    func testWatchAppsAllEnabled() {
        XCTAssertEqual(settings.watchApps, ["Microsoft Teams", "Zoom", "Webex"])
    }

    func testWatchAppsSingleDisabled() {
        settings.watchZoom = false
        XCTAssertEqual(settings.watchApps, ["Microsoft Teams", "Webex"])
    }

    func testWatchAppsAllDisabled() {
        settings.watchTeams = false
        settings.watchZoom = false
        settings.watchWebex = false
        XCTAssertEqual(settings.watchApps, [])
    }

    // MARK: - watchBrowserMeetings (issue #503)

    func testWatchBrowserMeetingsDefaultsOff() {
        XCTAssertFalse(settings.watchBrowserMeetings)
        XCTAssertFalse(
            settings.watchApps.contains("Google Chrome"),
            "browser watching is opt-in, so Chrome must not be watched by default",
        )
    }

    func testWatchBrowserMeetingsAppendsTheBrowserCategoryToWatchApps() {
        // The appended token is the browser *category*, deliberately a name no
        // real process carries: individual browsers are identified per process
        // at detection time, so this one token switches the whole family on.
        settings.watchBrowserMeetings = true
        XCTAssertEqual(settings.watchApps, ["Microsoft Teams", "Zoom", "Webex", "Browser Meetings"])
    }

    func testWatchBrowserMeetingsPersists() {
        settings.watchBrowserMeetings = true
        let fresh = AppSettings(defaults: defaults)
        XCTAssertTrue(fresh.watchBrowserMeetings)
    }

    // MARK: - Claude CLI

    #if !APPSTORE
        func testClaudeBinDefault() {
            XCTAssertEqual(settings.claudeBin, "claude")
        }

        func testClaudeBinSavedToDefaults() {
            settings.claudeBin = "claude-work"
            XCTAssertEqual(defaults.string(forKey: "claudeBin"), "claude-work")
        }

        func testDebugRPCEnabledDefault() {
            XCTAssertFalse(settings.debugRPCEnabled)
        }

        func testDebugRPCEnabledPersistence() {
            settings.debugRPCEnabled = true
            XCTAssertTrue(defaults.bool(forKey: "debugRPCEnabled"))
            // Verify a fresh instance reads it back from the same suite.
            let fresh = AppSettings(defaults: defaults)
            XCTAssertTrue(fresh.debugRPCEnabled)
        }
    #endif

    // MARK: - WhisperKit Model

    func testWhisperKitModelSavedToDefaults() {
        settings.whisperKitModel = "openai_whisper-small"
        XCTAssertEqual(defaults.string(forKey: "whisperKitModel"), "openai_whisper-small")
    }

    func testMicNameSavedToDefaults() {
        settings.micName = "Speaker A"
        XCTAssertEqual(defaults.string(forKey: "micName"), "Speaker A")
    }

    // MARK: - Protocol Provider

    func testProtocolProviderDefault() {
        #if APPSTORE
            XCTAssertEqual(settings.protocolProvider, .openAICompatible)
        #else
            XCTAssertEqual(settings.protocolProvider, .claudeCLI)
        #endif
    }

    func testProtocolProviderPersistence() {
        settings.protocolProvider = .openAICompatible
        XCTAssertEqual(
            defaults.string(forKey: "protocolProvider"),
            "openAICompatible",
        )
        // Verify a fresh instance reads it back from the same suite.
        let fresh = AppSettings(defaults: defaults)
        XCTAssertEqual(fresh.protocolProvider, .openAICompatible)
    }

    func testTranscriptOutputOptionsDefaultToEnabled() {
        XCTAssertTrue(settings.includeFullTranscriptInProtocol)
        XCTAssertTrue(settings.saveRawTranscriptSeparately)
    }

    func testTranscriptOutputOptionsPersist() {
        settings.includeFullTranscriptInProtocol = false
        settings.saveRawTranscriptSeparately = false
        XCTAssertEqual(defaults.object(forKey: "includeFullTranscriptInProtocol") as? Bool, false)
        XCTAssertEqual(defaults.object(forKey: "saveRawTranscriptSeparately") as? Bool, false)

        let fresh = AppSettings(defaults: defaults)
        XCTAssertFalse(fresh.includeFullTranscriptInProtocol)
        XCTAssertFalse(fresh.saveRawTranscriptSeparately)
    }

    func testOpenAIEndpointDefault() {
        XCTAssertEqual(settings.openAIEndpoint, "http://localhost:11434/v1")
    }

    func testOpenAIModelDefault() {
        XCTAssertEqual(settings.openAIModel, "llama3.1")
    }

    func testOpenAIAPIKeyViaKeychainHelper() {
        // The account is unique to this test and removed in tearDown, so there
        // is no shared slot to reset up front. Asserting through
        // `apiKeyAccount` also proves AppSettings honours the injection: were
        // it to fall back to the hardcoded production account, every read here
        // would come back nil.
        XCTAssertEqual(settings.openAIAPIKey, "")

        settings.openAIAPIKey = "sk-test-key"
        XCTAssertEqual(KeychainHelper.read(key: apiKeyAccount), "sk-test-key")
        XCTAssertEqual(settings.openAIAPIKey, "sk-test-key")

        settings.openAIAPIKey = ""
        XCTAssertNil(KeychainHelper.read(key: apiKeyAccount))
        XCTAssertEqual(settings.openAIAPIKey, "")
    }

    func testOpenAIEndpointSavedToDefaults() {
        settings.openAIEndpoint = "http://localhost:8080/v1/chat/completions"
        XCTAssertEqual(
            defaults.string(forKey: "openAIEndpoint"),
            "http://localhost:8080/v1/chat/completions",
        )
    }

    func testOpenAIModelSavedToDefaults() {
        settings.openAIModel = "mistral"
        XCTAssertEqual(defaults.string(forKey: "openAIModel"), "mistral")
    }

    // MARK: - Update Settings

    func testCheckForUpdatesDefault() {
        XCTAssertTrue(settings.checkForUpdates)
    }

    func testIncludePreReleasesDefault() {
        XCTAssertFalse(settings.includePreReleases)
    }

    func testCheckForUpdatesPersistence() {
        settings.checkForUpdates = false
        XCTAssertFalse(defaults.bool(forKey: "checkForUpdates"))
    }

    func testIncludePreReleasesPersistence() {
        settings.includePreReleases = true
        XCTAssertTrue(defaults.bool(forKey: "includePreReleases"))
    }

    // MARK: - Record Only

    func test_recordOnly_defaultsToFalse() {
        XCTAssertFalse(settings.recordOnly)
    }

    func test_recordOnly_persistsToUserDefaults() {
        settings.recordOnly = true
        XCTAssertTrue(defaults.bool(forKey: "recordOnly"))
    }

    // MARK: - Verbose Diagnostics (legacy audioDebugLogging migration)

    func test_verboseDiagnostics_defaultsToFalse() {
        XCTAssertFalse(settings.verboseDiagnostics)
    }

    func test_verboseDiagnostics_persistsUnderNewKey() {
        settings.verboseDiagnostics = true
        XCTAssertTrue(defaults.bool(forKey: "verboseDiagnostics"))
    }

    func test_verboseDiagnostics_migratesFromLegacyAudioDebugLoggingKey() {
        let suiteName = "AppSettingsTests-migration-\(UUID().uuidString)"
        guard let suite = UserDefaults(suiteName: suiteName) else {
            XCTFail("Could not create suite")
            return
        }
        defer { UserDefaults().removePersistentDomain(forName: suiteName) }

        suite.set(true, forKey: "audioDebugLogging")

        let migrated = AppSettings(defaults: suite)
        XCTAssertTrue(migrated.verboseDiagnostics)
        XCTAssertTrue(suite.bool(forKey: "verboseDiagnostics"))
    }

    func test_verboseDiagnostics_newKeyTakesPrecedenceOverLegacy() {
        let suiteName = "AppSettingsTests-precedence-\(UUID().uuidString)"
        guard let suite = UserDefaults(suiteName: suiteName) else {
            XCTFail("Could not create suite")
            return
        }
        defer { UserDefaults().removePersistentDomain(forName: suiteName) }

        suite.set(true, forKey: "audioDebugLogging")
        suite.set(false, forKey: "verboseDiagnostics")

        let migrated = AppSettings(defaults: suite)
        XCTAssertFalse(migrated.verboseDiagnostics)
    }

    func test_verboseDiagnostics_migrationRemovesLegacyKey() {
        let suiteName = "AppSettingsTests-cleanup-\(UUID().uuidString)"
        guard let suite = UserDefaults(suiteName: suiteName) else {
            XCTFail("Could not create suite")
            return
        }
        defer { UserDefaults().removePersistentDomain(forName: suiteName) }

        suite.set(true, forKey: "audioDebugLogging")

        _ = AppSettings(defaults: suite)

        XCTAssertNil(
            suite.object(forKey: "audioDebugLogging"),
            "Legacy audioDebugLogging key should be removed once migrated to verboseDiagnostics",
        )
        XCTAssertTrue(suite.bool(forKey: "verboseDiagnostics"))
    }

    // MARK: - Diarizer Tuning (Experimental)

    func testDiarizerTuningDefaults() {
        XCTAssertEqual(settings.clusterThreshold, 0.6)
        XCTAssertEqual(settings.warmStartFa, 0.07)
        XCTAssertEqual(settings.warmStartFb, 0.8)
        XCTAssertEqual(settings.minSegmentDurationSeconds, 1.0)
        XCTAssertTrue(settings.excludeOverlap)
        XCTAssertTrue(settings.diarizerTuningIsAllDefaults)
    }

    func testDiarizerTuningRoundTrip() {
        settings.clusterThreshold = 0.42
        settings.warmStartFa = 0.13
        settings.warmStartFb = 1.25
        settings.minSegmentDurationSeconds = 2.5
        settings.excludeOverlap = false

        // Persisted under the documented keys.
        XCTAssertEqual(defaults.double(forKey: "diarizerClusterThreshold"), 0.42)
        XCTAssertEqual(defaults.double(forKey: "diarizerWarmStartFa"), 0.13)
        XCTAssertEqual(defaults.double(forKey: "diarizerWarmStartFb"), 1.25)
        XCTAssertEqual(defaults.double(forKey: "diarizerMinSegmentDuration"), 2.5)
        XCTAssertFalse(defaults.bool(forKey: "diarizerExcludeOverlap"))

        // Fresh instance reads the same suite back.
        let fresh = AppSettings(defaults: defaults)
        XCTAssertEqual(fresh.clusterThreshold, 0.42)
        XCTAssertEqual(fresh.warmStartFa, 0.13)
        XCTAssertEqual(fresh.warmStartFb, 1.25)
        XCTAssertEqual(fresh.minSegmentDurationSeconds, 2.5)
        XCTAssertFalse(fresh.excludeOverlap)
        XCTAssertFalse(fresh.diarizerTuningIsAllDefaults)
    }

    func testResetDiarizerTuningRestoresDefaults() {
        settings.clusterThreshold = 0.42
        settings.warmStartFa = 0.13
        settings.warmStartFb = 1.25
        settings.minSegmentDurationSeconds = 2.5
        settings.excludeOverlap = false

        XCTAssertFalse(settings.diarizerTuningIsAllDefaults)

        settings.resetDiarizerTuning()

        XCTAssertEqual(settings.clusterThreshold, 0.6)
        XCTAssertEqual(settings.warmStartFa, 0.07)
        XCTAssertEqual(settings.warmStartFb, 0.8)
        XCTAssertEqual(settings.minSegmentDurationSeconds, 1.0)
        XCTAssertTrue(settings.excludeOverlap)
        XCTAssertTrue(settings.diarizerTuningIsAllDefaults)
    }

    // MARK: - Keychain

    func testKeychainRoundTrip() {
        KeychainHelper.delete(key: "HF_TOKEN_TEST")

        XCTAssertFalse(KeychainHelper.exists(key: "HF_TOKEN_TEST"))
        XCTAssertNil(KeychainHelper.read(key: "HF_TOKEN_TEST"))

        KeychainHelper.save(key: "HF_TOKEN_TEST", value: "hf_abc123")
        XCTAssertTrue(KeychainHelper.exists(key: "HF_TOKEN_TEST"))
        XCTAssertEqual(KeychainHelper.read(key: "HF_TOKEN_TEST"), "hf_abc123")

        KeychainHelper.save(key: "HF_TOKEN_TEST", value: "hf_xyz789")
        XCTAssertEqual(KeychainHelper.read(key: "HF_TOKEN_TEST"), "hf_xyz789")

        KeychainHelper.delete(key: "HF_TOKEN_TEST")
        XCTAssertFalse(KeychainHelper.exists(key: "HF_TOKEN_TEST"))
        XCTAssertNil(KeychainHelper.read(key: "HF_TOKEN_TEST"))
    }

    /// `DiarizerMode` is persisted via `PipelineSnapshot` (PipelineJob.usedDiarizerMode)
    /// and via UserDefaults (AppSettings.diarizerMode). The JSON/UserDefaults
    /// shape is keyed off the implicit rawValues `"offline"` / `"sortformer"`
    /// — a future case rename without a stable rawValue would silently break
    /// snapshot decode. This test pins the wire format so any rename forces
    /// an explicit migration decision.
    func testDiarizerModeRawValuesPinJSONShape() throws {
        XCTAssertEqual(DiarizerMode.offline.rawValue, "offline")
        XCTAssertEqual(DiarizerMode.sortformer.rawValue, "sortformer")

        let json = try JSONEncoder().encode([DiarizerMode.offline, .sortformer])
        XCTAssertEqual(String(bytes: json, encoding: .utf8), #"["offline","sortformer"]"#)

        let roundTrip = try JSONDecoder().decode([DiarizerMode].self, from: json)
        XCTAssertEqual(roundTrip, [.offline, .sortformer])
    }

    /// `DiarizerMode.speakerCap` is the single source of truth for the
    /// max-speaker constraint shared by `SpeakersSettingsView` and
    /// `SpeakerNamingView`. Lock the values so a FluidAudio bump that
    /// changes Sortformer's cap will surface here first.
    func testDiarizerModeSpeakerCap() {
        XCTAssertEqual(DiarizerMode.sortformer.speakerCap, 4)
        XCTAssertEqual(DiarizerMode.offline.speakerCap, 10)
    }
}
