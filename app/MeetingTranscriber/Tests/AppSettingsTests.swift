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
    private var secretsDir: URL!

    /// Each test gets its own volatile `UserDefaults(suiteName:)` plus a
    /// dedicated temp `secretsDir`, so `swift test --parallel` doesn't race
    /// on the shared on-disk plist or the file-based API-key storage.
    override func setUp() {
        super.setUp()
        testSuiteName = "AppSettingsTests-\(getpid())-\(UUID().uuidString)"
        guard let suite = UserDefaults(suiteName: testSuiteName) else {
            XCTFail("Could not create test UserDefaults suite")
            return
        }
        defaults = suite
        secretsDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("AppSettingsTests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: secretsDir, withIntermediateDirectories: true)
        settings = AppSettings(defaults: defaults, secretsDir: secretsDir)
    }

    override func tearDown() {
        settings = nil
        defaults.removePersistentDomain(forName: testSuiteName)
        defaults = nil
        testSuiteName = nil
        try? FileManager.default.removeItem(at: secretsDir)
        secretsDir = nil
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
        XCTAssertEqual(settings.openAIEndpoint, "http://localhost:11434/v1/chat/completions")
    }

    func testOpenAIModelDefault() {
        XCTAssertEqual(settings.openAIModel, "llama3.1")
    }

    func testOpenAIAPIKeyRoundTripsThroughFile() {
        XCTAssertEqual(settings.openAIAPIKey, "")
        let keyFile = secretsDir.appendingPathComponent(".openai-key")
        XCTAssertFalse(FileManager.default.fileExists(atPath: keyFile.path))

        settings.openAIAPIKey = "sk-test-key"
        XCTAssertEqual(settings.openAIAPIKey, "sk-test-key")
        XCTAssertEqual(try String(contentsOf: keyFile, encoding: .utf8), "sk-test-key")

        // Confirm file mode is 0600 — secret must not be world- or group-readable.
        let attrs = try? FileManager.default.attributesOfItem(atPath: keyFile.path)
        XCTAssertEqual(attrs?[.posixPermissions] as? Int, 0o600)

        settings.openAIAPIKey = ""
        XCTAssertEqual(settings.openAIAPIKey, "")
        XCTAssertFalse(FileManager.default.fileExists(atPath: keyFile.path))
    }

    func testOpenAIAPIKeyPersistsAcrossInstances() {
        settings.openAIAPIKey = "sk-persistent"
        // New AppSettings against the same secretsDir should read the file
        // back — the round-trip is what the user sees after relaunch.
        let reloaded = AppSettings(defaults: defaults, secretsDir: secretsDir)
        XCTAssertEqual(reloaded.openAIAPIKey, "sk-persistent")
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
}
