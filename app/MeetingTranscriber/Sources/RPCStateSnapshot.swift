#if !APPSTORE
    import Foundation

    /// JSON-serialisable snapshot of state useful for shell inspection.
    /// Deliberately minimal — extend as endpoints need it.
    struct RPCStateSnapshot: Codable {
        let pipeline: Pipeline
        let speakerDB: SpeakerDB
        let pendingNamingJobs: [PendingNaming]
        let engines: Engines

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
        ) {
            self.pipeline = pipeline
            self.speakerDB = speakerDB
            self.pendingNamingJobs = pendingNamingJobs
            self.engines = engines
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
