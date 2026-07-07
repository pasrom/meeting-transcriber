#if !APPSTORE
    import Foundation

    /// JSON-serialisable snapshot of state useful for shell inspection.
    /// Deliberately minimal — extend as endpoints need it.
    struct RPCStateSnapshot: Codable {
        let pipeline: Pipeline
        let speakerDB: SpeakerDB
        let pendingNamingJobs: [PendingNaming]
        let engines: Engines
        /// The most recent pipeline job that finished — `.done` or `.error`.
        /// Surfaced so a driver script can poll `/state` (or hit `/jobs/last`)
        /// and assert on the outcome of a triggered meeting without needing
        /// to scrape disk paths from logs.
        let lastJob: LastJob?
        /// Per-channel capture-health flags. True while the channel has been
        /// silent (vs the other side carrying audio) longer than
        /// `asymmetricSilenceWarningSeconds`. E2E drivers poll these to assert
        /// the menu-bar red-tint indicator wiring without screenshot OCR.
        let channelHealth: ChannelHealth
        /// Permission health: per-permission TCC+probe verdict ("healthy",
        /// "denied", "broken", "notDetermined", or "unknown" before the first
        /// check). E2E drivers poll this to assert the probes don't false-flag a
        /// granted permission (issue #446) without screenshotting the menu bar.
        let permissionHealth: PermissionHealth
        /// Snapshot of the live-caption overlay state. E2E drivers poll
        /// `recentFinals.count > 0` to assert that the full live-transcription
        /// chain produced text without scraping the OSLog or screenshotting
        /// the overlay panel.
        let liveCaptions: LiveCaptions
        /// Current watch-loop state (`WatchLoop.State` raw value: "idle",
        /// "watching", "recording", "error"), nil when no watch loop exists.
        /// Lets driver scripts gate a measurement window on
        /// `watchState == "recording"` when no caption signal is available
        /// (live transcription off — the default user profile).
        let watchState: String?
        /// True while the active recording is a manual (app-picker) recording
        /// rather than an auto-detected meeting. `watchState` reads "recording"
        /// for both, so this is the only wire signal that distinguishes the
        /// manual-recording path — letting a driver assert it took that path.
        let isManualRecording: Bool
        /// Recently-posted macOS notifications (capped ring buffer, oldest
        /// dropped), chronological — newest last. E2E drivers poll this to
        /// assert user-facing warning paths (meeting detected, silent recording,
        /// permission problems, sidecar-write failures) actually fired, which is
        /// otherwise unobservable from outside the process.
        let notifications: [Notification]
        /// Read-only projection of the app's EFFECTIVE settings — the values the
        /// running process actually resolved from UserDefaults. E2E driver
        /// scripts configure the app by writing UserDefaults blind (`defaults
        /// write` / CFPreferences) and otherwise can't confirm what the app
        /// sees; `defaults read` is unreliable for the dev bundle (container-plist
        /// redirect). Secrets (OpenAI API key, any Keychain value) are never
        /// included — see `AppSettings.rpcSettingsSnapshot()`.
        let settings: Settings
        /// The current menu-bar `BadgeKind` — the single glanceable summary a
        /// human reads off the menu bar. Exposing it lets a driver script assert
        /// the app reflects the right state deterministically instead of counting
        /// red pixels in a `/screenshot`. Serialises to the `BadgeKind` case-name
        /// raw value (e.g. "recording"). Record-only mode is a separate
        /// persistent overlay; derive it from `settings.recording.recordOnly`.
        let badge: BadgeKind
        /// Update-checker runtime status. E2E drivers assert the update-check flow
        /// (the found version, an in-flight check, a check error) that the badge
        /// only summarises as the boolean `.updateAvailable`. Named `updateStatus`
        /// (not `updates`) to avoid clashing with `settings.updates`, the user's
        /// update *preferences* — mirroring the `permissionHealth` status family.
        /// Contains no secrets.
        let updateStatus: UpdateStatus

        struct UpdateStatus: Codable {
            /// True when a release newer than the running version was found.
            let available: Bool
            /// The available release's tag (e.g. "v1.2.3"); nil when none.
            let availableVersion: String?
            /// Whether the available release is a pre-release; false when none.
            let isPrerelease: Bool
            /// True while an update check is in flight.
            let isChecking: Bool
            /// The last check's error message; nil on success / not-yet-checked.
            let lastError: String?

            static let empty = Self(
                available: false, availableVersion: nil, isPrerelease: false,
                isChecking: false, lastError: nil,
            )
        }

        struct Pipeline: Codable {
            let isProcessing: Bool
            let activeJobCount: Int
            let waitingJobCount: Int
            let pendingNamingJobCount: Int
        }

        struct SpeakerDB: Codable {
            let count: Int
            /// Top-10 names ranked by recency, read fresh from the matcher on
            /// every snapshot — independent of any cache.
            let recentNames: [String]
            /// `PipelineQueue.knownSpeakerNames` — the cache the next naming
            /// dialog reads. Surfaced separately so smoketests can verify the
            /// invalidation flow (#155 → #158 → #159).
            let knownSpeakerNames: [String]
        }

        struct PendingNaming: Codable {
            let jobID: String
            let meetingTitle: String
            let speakerCount: Int
            let namingSlug: String?
        }

        struct LiveCaptions: Codable {
            let hypothesisMic: String
            let hypothesisApp: String
            let recentFinals: [LiveCaptionLine]

            static let empty = Self(hypothesisMic: "", hypothesisApp: "", recentFinals: [])
        }

        struct ChannelHealth: Codable {
            let micSilent: Bool
            let appSilent: Bool
            /// True while *both* channels have been below silence threshold
            /// continuously past the debounce window — the failure mode
            /// `ChannelHealthMonitor` intentionally ignores (symmetric
            /// silence). Surfaced separately so e2e drivers can assert on
            /// the polling chain wired up to `SilentRecordingMonitor`
            /// without screenshot OCR.
            let recordingSilent: Bool

            static let inactive = Self(
                micSilent: false,
                appSilent: false,
                recordingSilent: false,
            )
        }

        struct PermissionHealth: Codable {
            let screenRecording: String
            let microphone: String
            let accessibility: String
            /// Mirror of `HealthCheckResult.isHealthy` — true only when every
            /// permission is healthy. Lets drivers assert the aggregate without
            /// re-deriving it from the three strings.
            let isHealthy: Bool

            /// Pre-check placeholder: the health check runs asynchronously at
            /// launch, so a snapshot taken before it completes reports "unknown".
            static let unknown = Self(
                screenRecording: "unknown",
                microphone: "unknown",
                accessibility: "unknown",
                isHealthy: false,
            )
        }

        struct Notification: Codable {
            let title: String
            let body: String
            /// ISO-8601 wall-clock time the notification was posted.
            let postedAt: String
            /// Whether it passed the delivery guard and reached
            /// `UNUserNotificationCenter`. Assertions about user-VISIBLE
            /// warnings must require `true`; `false` means the app only
            /// *decided* to notify (headless context, setup not run).
            let delivered: Bool
        }

        struct LastJob: Codable {
            let jobID: String
            let state: JobState
            let meetingTitle: String
            let appName: String
            /// Wall-clock seconds from `enqueuedAt` to snapshot time.
            let durationSec: Double
            let transcriptPath: String?
            let protocolPath: String?
            let error: String?
            let warnings: [String]
            let participants: [String]
        }

        struct Engines: Codable {
            let active: TranscriptionEngineSetting
            let whisperKit: WhisperKit
            let parakeet: Parakeet

            // `modelState` (stringified `EngineModelState`, e.g. "unloaded"/"loaded")
            // lets driver scripts wait for model preload before measuring —
            // pipeline state tracks jobs, not loads (used by e2e-cpu-load.sh).

            struct WhisperKit: Codable {
                let modelVariant: String
                /// `nil` = auto-detect (matches `language: nil` on `DecodingOptions`).
                let language: String?
                let modelState: String
            }

            struct Parakeet: Codable {
                let customVocabularyPath: String
                let modelState: String
            }

            static let empty = Self(
                active: .whisperKit,
                whisperKit: .init(modelVariant: "", language: nil, modelState: ""),
                parakeet: .init(customVocabularyPath: "", modelState: ""),
            )
        }

        /// Read-only projection of the non-secret `AppSettings` scalars, enum
        /// raw values, and paths. Grouped into sub-objects that mirror the
        /// Settings-window tabs. Built by `AppSettings.rpcSettingsSnapshot()`.
        /// NEVER carries secrets: the OpenAI API key and any other
        /// Keychain-backed value are deliberately excluded.
        struct Settings: Codable {
            let detection: Detection
            let recording: Recording
            let transcription: Transcription
            let diarization: Diarization
            let protocolGeneration: ProtocolGeneration
            let output: Output
            let diagnostics: Diagnostics
            let updates: Updates

            struct Detection: Codable {
                let watchTeams: Bool
                let watchZoom: Bool
                let watchWebex: Bool
                let autoWatch: Bool
                let pollIntervalSeconds: Double

                static let empty = Self(
                    watchTeams: false, watchZoom: false, watchWebex: false,
                    autoWatch: false, pollIntervalSeconds: 0,
                )
            }

            struct Recording: Codable {
                let endGraceSeconds: Double
                let noMic: Bool
                let recordOnly: Bool
                /// CoreAudio device UID; empty string = system default.
                let micDeviceUID: String
                let micName: String
                let perChannelIndicatorEnabled: Bool
                let liveTranscriptionEnabled: Bool
                let asymmetricSilenceWarningSeconds: Double

                static let empty = Self(
                    endGraceSeconds: 0, noMic: false, recordOnly: false,
                    micDeviceUID: "", micName: "", perChannelIndicatorEnabled: false,
                    liveTranscriptionEnabled: false, asymmetricSilenceWarningSeconds: 0,
                )
            }

            struct Transcription: Codable {
                /// `TranscriptionEngineSetting` raw value ("whisperKit" | "parakeet").
                let engine: String
                let whisperKitModel: String
                /// Empty string = auto-detect (mirrors the UserDefaults sentinel).
                let whisperLanguage: String
                let parakeetLanguage: String
                let customVocabularyPath: String

                static let empty = Self(
                    engine: "", whisperKitModel: "", whisperLanguage: "",
                    parakeetLanguage: "", customVocabularyPath: "",
                )
            }

            struct Diarization: Codable {
                let diarize: Bool
                /// `DiarizerMode` raw value ("offline" | "sortformer").
                let mode: String
                /// 0 = auto-detect speaker count.
                let numSpeakers: Int
                let vadEnabled: Bool
                let vadThreshold: Float
                let clusterThreshold: Double
                let warmStartFa: Double
                let warmStartFb: Double
                let minSegmentDurationSeconds: Double
                let excludeOverlap: Bool

                static let empty = Self(
                    diarize: false, mode: "", numSpeakers: 0, vadEnabled: false,
                    vadThreshold: 0, clusterThreshold: 0, warmStartFa: 0,
                    warmStartFb: 0, minSegmentDurationSeconds: 0, excludeOverlap: false,
                )
            }

            struct ProtocolGeneration: Codable {
                /// `ProtocolProvider` raw value ("claudeCLI" | "openAICompatible" | "none").
                let provider: String
                let language: String
                let openAIEndpoint: String
                let openAIModel: String
                /// Claude CLI binary name/path (non-secret). The App Store build
                /// never compiles this file (`#if !APPSTORE`).
                let claudeBin: String

                static let empty = Self(
                    provider: "", language: "", openAIEndpoint: "",
                    openAIModel: "", claudeBin: "",
                )
            }

            struct Output: Codable {
                /// Effective output directory the app writes to. `nil` when a
                /// custom bookmark is set but not cheaply resolvable right now
                /// (e.g. the volume is detached) — the snapshot never mounts,
                /// never repairs bookmarks, and never blocks on I/O for this.
                let directory: String?
                /// A user-picked custom output dir (security-scoped bookmark) is
                /// set, vs the default ~/Downloads/MeetingTranscriber.
                let hasCustomDirectory: Bool
                /// A custom protocol-prompt file exists on disk. The content is
                /// intentionally not exposed (potentially large / user-authored).
                let hasCustomPrompt: Bool

                static let empty = Self(directory: nil, hasCustomDirectory: false, hasCustomPrompt: false)
            }

            struct Diagnostics: Codable {
                let verboseDiagnostics: Bool
                let debugRPCEnabled: Bool

                static let empty = Self(verboseDiagnostics: false, debugRPCEnabled: false)
            }

            struct Updates: Codable {
                let checkForUpdates: Bool
                let includePreReleases: Bool

                static let empty = Self(checkForUpdates: false, includePreReleases: false)
            }

            /// Placeholder for snapshots built without a live `AppSettings`
            /// (test fixtures, `RPCStateSnapshot.empty`).
            static let empty = Self(
                detection: .empty, recording: .empty, transcription: .empty,
                diarization: .empty, protocolGeneration: .empty, output: .empty,
                diagnostics: .empty, updates: .empty,
            )
        }

        init(
            pipeline: Pipeline,
            speakerDB: SpeakerDB,
            pendingNamingJobs: [PendingNaming],
            engines: Engines = .empty,
            lastJob: LastJob? = nil,
            channelHealth: ChannelHealth = .inactive,
            permissionHealth: PermissionHealth = .unknown,
            liveCaptions: LiveCaptions = .empty,
            watchState: String? = nil,
            isManualRecording: Bool = false,
            notifications: [Notification] = [],
            settings: Settings = .empty,
            badge: BadgeKind = .inactive,
            updateStatus: UpdateStatus = .empty,
        ) {
            self.pipeline = pipeline
            self.speakerDB = speakerDB
            self.pendingNamingJobs = pendingNamingJobs
            self.engines = engines
            self.lastJob = lastJob
            self.channelHealth = channelHealth
            self.permissionHealth = permissionHealth
            self.liveCaptions = liveCaptions
            self.watchState = watchState
            self.isManualRecording = isManualRecording
            self.notifications = notifications
            self.settings = settings
            self.badge = badge
            self.updateStatus = updateStatus
        }

        func jsonData() throws -> Data {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            return try encoder.encode(self)
        }

        static let empty = Self(
            pipeline: .init(
                isProcessing: false, activeJobCount: 0,
                waitingJobCount: 0, pendingNamingJobCount: 0,
            ),
            speakerDB: .init(count: 0, recentNames: [], knownSpeakerNames: []),
            pendingNamingJobs: [],
        )
    }
#endif
