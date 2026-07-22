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

    /// Each test gets its own volatile `UserDefaults(suiteName:)` so
    /// `swift test --parallel` doesn't race on the shared on-disk plist.
    /// AppSettings receives the suite via constructor injection.
    ///
    /// Keychain state is per-user (not per-process), so we deliberately do
    /// NOT touch any production keychain accounts here — `swift test
    /// --parallel` spawns a fresh `xctest` process per test method, and an
    /// unconditional delete in setUp would race with the write performed
    /// by `testOpenAIAPIKeyViaKeychainHelper` running in a sibling process.
    /// The one test that needs a clean keychain slot manages the slot
    /// itself.
    override func setUp() {
        super.setUp()
        testSuiteName = "AppSettingsTests-\(getpid())-\(UUID().uuidString)"
        guard let suite = UserDefaults(suiteName: testSuiteName) else {
            XCTFail("Could not create test UserDefaults suite")
            return
        }
        defaults = suite
        settings = AppSettings(defaults: defaults)
    }

    override func tearDown() {
        settings = nil
        defaults.removePersistentDomain(forName: testSuiteName)
        defaults = nil
        testSuiteName = nil
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

    // MARK: - watchApps

    func testWatchAppsAllEnabled() {
        XCTAssertEqual(settings.watchApps, ["Microsoft Teams", "Zoom", "Webex", "Google Meet"])
    }

    func testWatchAppsSingleDisabled() {
        settings.watchZoom = false
        XCTAssertEqual(settings.watchApps, ["Microsoft Teams", "Webex", "Google Meet"])
    }

    func testWatchAppsAllDisabled() {
        settings.watchTeams = false
        settings.watchZoom = false
        settings.watchWebex = false
        settings.watchMeet = false
        XCTAssertEqual(settings.watchApps, [])
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

    func testOpenAIEndpointDefault() {
        XCTAssertEqual(settings.openAIEndpoint, "http://localhost:11434/v1")
    }

    func testOpenAIModelDefault() {
        XCTAssertEqual(settings.openAIModel, "llama3.1")
    }

    func testOpenAIAPIKeyViaKeychainHelper() {
        // Reset the keychain slot before + after so a crashed prior run
        // can't seed `"sk-test-key"` and a failure here doesn't leak it
        // to the next invocation.
        KeychainHelper.delete(key: "openAIAPIKey")
        defer { KeychainHelper.delete(key: "openAIAPIKey") }

        XCTAssertEqual(settings.openAIAPIKey, "")

        settings.openAIAPIKey = "sk-test-key"
        XCTAssertEqual(KeychainHelper.read(key: "openAIAPIKey"), "sk-test-key")
        XCTAssertEqual(settings.openAIAPIKey, "sk-test-key")

        settings.openAIAPIKey = ""
        XCTAssertNil(KeychainHelper.read(key: "openAIAPIKey"))
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
