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
            /// `nil` on macOS <15 where `Qwen3AsrEngine` isn't available.
            let qwen3: Qwen3?

            // `modelState` (stringified `ModelState`, e.g. "unloaded"/"loaded")
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

            struct Qwen3: Codable {
                let language: String?
                let modelState: String
            }

            static let empty = Self(
                active: .whisperKit,
                whisperKit: .init(modelVariant: "", language: nil, modelState: ""),
                parakeet: .init(customVocabularyPath: "", modelState: ""),
                qwen3: nil,
            )
        }

        init(
            pipeline: Pipeline,
            speakerDB: SpeakerDB,
            pendingNamingJobs: [PendingNaming],
            engines: Engines = .empty,
            lastJob: LastJob? = nil,
            channelHealth: ChannelHealth = .inactive,
            liveCaptions: LiveCaptions = .empty,
            watchState: String? = nil,
        ) {
            self.pipeline = pipeline
            self.speakerDB = speakerDB
            self.pendingNamingJobs = pendingNamingJobs
            self.engines = engines
            self.lastJob = lastJob
            self.channelHealth = channelHealth
            self.liveCaptions = liveCaptions
            self.watchState = watchState
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
