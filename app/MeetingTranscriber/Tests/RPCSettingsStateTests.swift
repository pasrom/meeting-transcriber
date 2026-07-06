#if !APPSTORE
    @testable import MeetingTranscriber
    import XCTest

    /// Verifies that `rpcStateSnapshot().settings` (and the
    /// `AppSettings.rpcSettingsSnapshot()` projection behind it) mirrors the
    /// EFFECTIVE settings so E2E driver scripts can read back what the app
    /// actually resolved instead of trusting a blind `defaults write`. Also
    /// pins that secrets never reach the wire.
    @MainActor
    final class RPCSettingsStateTests: XCTestCase {
        // swiftlint:disable:next implicitly_unwrapped_optional
        private var defaults: UserDefaults!
        // swiftlint:disable:next implicitly_unwrapped_optional
        private var settings: AppSettings!
        // swiftlint:disable:next implicitly_unwrapped_optional
        private var testSuiteName: String!

        override func setUp() async throws {
            try await super.setUp()
            testSuiteName = "RPCSettingsStateTests-\(getpid())-\(UUID().uuidString)"
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

        // MARK: - Snapshot mirrors defaults

        func test_snapshot_mirrorsDefaultSettings() {
            let s = settings.rpcSettingsSnapshot()

            // A representative default from each sub-object — enough to prove
            // the projection reads live values, not hardcoded zeros.
            XCTAssertTrue(s.detection.watchTeams)
            XCTAssertFalse(s.detection.autoWatch)
            XCTAssertEqual(s.detection.pollIntervalSeconds, 3.0)
            XCTAssertEqual(s.recording.endGraceSeconds, 15.0)
            XCTAssertFalse(s.recording.recordOnly)
            XCTAssertEqual(s.recording.micName, "Me")
            XCTAssertTrue(s.recording.perChannelIndicatorEnabled)
            XCTAssertEqual(s.recording.asymmetricSilenceWarningSeconds, 90.0)
            XCTAssertEqual(s.transcription.engine, "whisperKit")
            XCTAssertEqual(s.transcription.whisperLanguage, "de")
            XCTAssertTrue(s.diarization.diarize)
            XCTAssertEqual(s.diarization.mode, "offline")
            XCTAssertEqual(s.diarization.numSpeakers, 0)
            XCTAssertFalse(s.diarization.vadEnabled)
            XCTAssertEqual(s.diarization.clusterThreshold, AppSettings.DiarizerTuningDefaults.clusterThreshold)
            XCTAssertEqual(s.protocolGeneration.language, "German")
            XCTAssertTrue(s.updates.checkForUpdates)
            XCTAssertFalse(s.updates.includePreReleases)
        }

        // MARK: - Snapshot reflects flipped values (mutation-proof target)

        func test_snapshot_reflectsFlippedValues() {
            settings.autoWatch = true
            settings.recordOnly = true
            settings.liveTranscriptionEnabled = true
            settings.noMic = true
            settings.endGrace = 42
            settings.micName = "Bob"
            settings.micDeviceUID = "AppleUSBAudioEngine:Test"
            settings.numSpeakers = 3
            settings.vadEnabled = true
            settings.vadThreshold = 0.75
            settings.diarize = false
            settings.verboseDiagnostics = true
            settings.includePreReleases = true

            let s = settings.rpcSettingsSnapshot()

            XCTAssertTrue(s.detection.autoWatch)
            XCTAssertTrue(s.recording.recordOnly)
            XCTAssertTrue(s.recording.liveTranscriptionEnabled)
            XCTAssertTrue(s.recording.noMic)
            XCTAssertEqual(s.recording.endGraceSeconds, 42)
            XCTAssertEqual(s.recording.micName, "Bob")
            XCTAssertEqual(s.recording.micDeviceUID, "AppleUSBAudioEngine:Test")
            XCTAssertEqual(s.diarization.numSpeakers, 3)
            XCTAssertTrue(s.diarization.vadEnabled)
            XCTAssertEqual(s.diarization.vadThreshold, 0.75)
            XCTAssertFalse(s.diarization.diarize)
            XCTAssertTrue(s.diagnostics.verboseDiagnostics)
            XCTAssertTrue(s.updates.includePreReleases)
        }

        // MARK: - Enum raw-value mapping is pinned

        func test_snapshot_enumRawValuesMatchSourceEnums() {
            settings.transcriptionEngine = .parakeet
            settings.parakeetLanguage = "fr"
            settings.diarizerMode = .sortformer
            settings.protocolProvider = .openAICompatible

            let s = settings.rpcSettingsSnapshot()

            // Wire value IS the enum raw value — pin the exact strings AND the
            // fact they equal the source enums' rawValues, so a case rename
            // that changes the JSON shape breaks here.
            XCTAssertEqual(s.transcription.engine, "parakeet")
            XCTAssertEqual(s.transcription.engine, TranscriptionEngineSetting.parakeet.rawValue)
            XCTAssertEqual(s.transcription.parakeetLanguage, "fr")
            XCTAssertEqual(s.diarization.mode, "sortformer")
            XCTAssertEqual(s.diarization.mode, DiarizerMode.sortformer.rawValue)
            XCTAssertEqual(s.protocolGeneration.provider, "openAICompatible")
            XCTAssertEqual(s.protocolGeneration.provider, ProtocolProvider.openAICompatible.rawValue)
        }

        func test_snapshot_protocolProviderNone_mapsToNoneRawValue() {
            settings.protocolProvider = .none
            let s = settings.rpcSettingsSnapshot()
            XCTAssertEqual(s.protocolGeneration.provider, "none")
        }

        // MARK: - Output projection

        func test_snapshot_output_reflectsDefaultDirAndNoCustomBookmark() {
            let s = settings.rpcSettingsSnapshot()
            // Fresh suite → no custom bookmark → effective dir is the default.
            XCTAssertFalse(s.output.hasCustomDirectory)
            XCTAssertEqual(s.output.directory, AppPaths.downloadsProtocolsDir.path)
        }

        // MARK: - Secrets never reach the wire

        /// The ONLY secret `AppSettings` holds is the OpenAI API key, stored in
        /// the process-global macOS Keychain. We deliberately do NOT write that
        /// Keychain account here: it has no per-suite isolation and a second
        /// writer would race `AppSettingsTests.testOpenAIAPIKeyViaKeychainHelper`
        /// under `swift test --parallel` (a hazard that file already documents).
        /// Instead we pin the projection can never carry a secret — no
        /// secret-bearing field name or marker anywhere in the encoded JSON —
        /// while proving the guard isn't vacuous: the non-secret OpenAI fields
        /// that ARE exposed round-trip.
        func test_snapshot_neverEncodesSecrets() throws {
            settings.openAIEndpoint = "http://sentinel-endpoint.example/v1"
            settings.openAIModel = "sentinel-model-name"

            let snapshot = RPCStateSnapshot(
                pipeline: .init(
                    isProcessing: false, activeJobCount: 0,
                    waitingJobCount: 0, pendingNamingJobCount: 0,
                ),
                speakerDB: .init(count: 0, recentNames: [], knownSpeakerNames: []),
                pendingNamingJobs: [],
                settings: settings.rpcSettingsSnapshot(),
            )
            let json = try XCTUnwrap(String(bytes: snapshot.jsonData(), encoding: .utf8))

            // Non-secret exposed fields present → snapshot is non-vacuous.
            XCTAssertTrue(json.contains("sentinel-endpoint.example"))
            XCTAssertTrue(json.contains("sentinel-model-name"))

            // The one secret-bearing field name must never appear.
            XCTAssertFalse(json.contains("openAIAPIKey"), "secret field name leaked")
        }

        /// Exact key allowlist: the settings wire shape may only ever contain
        /// these leaf fields. Any new field must be consciously added here (and
        /// consciously judged non-secret); a secret slipping into the projection
        /// under ANY name fails this test, which generic substring scans can't
        /// guarantee.
        func test_snapshot_settingsKeysAreExactlyTheAllowlist() throws {
            let data = try JSONEncoder().encode(settings.rpcSettingsSnapshot())
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])

            var keys = Set<String>()
            func collect(_ dict: [String: Any], prefix: String) {
                for (key, value) in dict {
                    let path = prefix.isEmpty ? key : "\(prefix).\(key)"
                    if let nested = value as? [String: Any] {
                        collect(nested, prefix: path)
                    } else {
                        keys.insert(path)
                    }
                }
            }
            collect(object, prefix: "")

            let allowlist: Set = [
                "detection.watchTeams", "detection.watchZoom", "detection.watchWebex",
                "detection.autoWatch", "detection.pollIntervalSeconds",
                "recording.endGraceSeconds", "recording.noMic", "recording.recordOnly",
                "recording.micDeviceUID", "recording.micName",
                "recording.perChannelIndicatorEnabled", "recording.liveTranscriptionEnabled",
                "recording.asymmetricSilenceWarningSeconds",
                "transcription.engine", "transcription.whisperKitModel",
                "transcription.whisperLanguage", "transcription.parakeetLanguage",
                "transcription.customVocabularyPath",
                "diarization.diarize", "diarization.mode", "diarization.numSpeakers",
                "diarization.vadEnabled", "diarization.vadThreshold",
                "diarization.clusterThreshold", "diarization.warmStartFa",
                "diarization.warmStartFb", "diarization.minSegmentDurationSeconds",
                "diarization.excludeOverlap",
                "protocolGeneration.provider", "protocolGeneration.language",
                "protocolGeneration.openAIEndpoint", "protocolGeneration.openAIModel",
                "protocolGeneration.claudeBin",
                "output.directory", "output.hasCustomDirectory", "output.hasCustomPrompt",
                "diagnostics.verboseDiagnostics", "diagnostics.debugRPCEnabled",
                "updates.checkForUpdates", "updates.includePreReleases",
            ]
            XCTAssertEqual(keys, allowlist)
        }

        // MARK: - JSON round-trip

        func test_snapshot_settingsJSONRoundtrips() throws {
            settings.recordOnly = true
            settings.transcriptionEngine = .parakeet
            settings.numSpeakers = 4
            settings.diarizerMode = .sortformer

            let snapshot = RPCStateSnapshot(
                pipeline: .init(
                    isProcessing: false, activeJobCount: 0,
                    waitingJobCount: 0, pendingNamingJobCount: 0,
                ),
                speakerDB: .init(count: 0, recentNames: [], knownSpeakerNames: []),
                pendingNamingJobs: [],
                settings: settings.rpcSettingsSnapshot(),
            )
            let decoded = try JSONDecoder().decode(
                RPCStateSnapshot.self, from: snapshot.jsonData(),
            )

            XCTAssertTrue(decoded.settings.recording.recordOnly)
            XCTAssertEqual(decoded.settings.transcription.engine, "parakeet")
            XCTAssertEqual(decoded.settings.diarization.numSpeakers, 4)
            XCTAssertEqual(decoded.settings.diarization.mode, "sortformer")
        }

        // MARK: - Wired through AppState

        /// End-to-end within the process: the snapshot AppState hands the RPC
        /// server carries the live settings, so `mt-cli state | jq .settings`
        /// against the running app reflects a runtime change.
        func test_appStateSnapshot_carriesLiveSettings() {
            settings.recordOnly = true
            settings.transcriptionEngine = .parakeet
            let state = AppState(settings: settings)

            let s = state.rpcStateSnapshot().settings

            XCTAssertTrue(s.recording.recordOnly)
            XCTAssertEqual(s.transcription.engine, "parakeet")
        }
    }
#endif
