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

        struct ChannelHealth: Codable {
            let micSilent: Bool
            let appSilent: Bool

            static let inactive = Self(micSilent: false, appSilent: false)
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

            struct WhisperKit: Codable {
                let modelVariant: String
                /// `nil` = auto-detect (matches `language: nil` on `DecodingOptions`).
                let language: String?
            }

            struct Parakeet: Codable {
                let customVocabularyPath: String
            }

            struct Qwen3: Codable {
                let language: String?
            }

            static let empty = Self(
                active: .whisperKit,
                whisperKit: .init(modelVariant: "", language: nil),
                parakeet: .init(customVocabularyPath: ""),
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
        ) {
            self.pipeline = pipeline
            self.speakerDB = speakerDB
            self.pendingNamingJobs = pendingNamingJobs
            self.engines = engines
            self.lastJob = lastJob
            self.channelHealth = channelHealth
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
