#if !APPSTORE
    import Foundation

    extension AppState {
        /// Build a snapshot of state for the debug RPC. Read-only.
        func rpcStateSnapshot() -> RPCStateSnapshot {
            let stored = SpeakerMatcher().loadDB()
            let recentNames = SpeakerMatcher.rankByRecency(speakers: stored)
                .prefix(10).map(\.name)
            let pendingJobs = pipelineQueue.pendingSpeakerNamingJobs.map { job in
                let data = pipelineQueue.speakerNamingDataByJob[job.id]
                return RPCStateSnapshot.PendingNaming(
                    jobID: job.id.uuidString,
                    meetingTitle: job.meetingTitle,
                    speakerCount: data?.mapping.count ?? 0,
                    namingSlug: job.namingSlug,
                )
            }
            return RPCStateSnapshot(
                pipeline: .init(
                    isProcessing: pipelineQueue.isProcessing,
                    activeJobCount: pipelineQueue.activeJobs.count,
                    waitingJobCount: pipelineQueue.pendingJobs.count,
                    pendingNamingJobCount: pendingJobs.count,
                ),
                speakerDB: .init(
                    count: stored.count,
                    recentNames: recentNames,
                    knownSpeakerNames: pipelineQueue.knownSpeakerNames,
                ),
                pendingNamingJobs: pendingJobs,
                engines: enginesSnapshot(),
                lastJob: lastFinishedJobSnapshot(),
                channelHealth: .init(
                    micSilent: micSilentActive,
                    appSilent: appSilentActive,
                    recordingSilent: recordingSilentActive,
                ),
            )
        }

        /// Most recent `.done`-or-`.error` job from the queue, mapped to the
        /// snapshot shape. Used by E2E driver scripts to assert on outcome
        /// after triggering a meeting.
        private func lastFinishedJobSnapshot() -> RPCStateSnapshot.LastJob? {
            guard let job = pipelineQueue.jobs.last(where: { job in
                job.state == .done || job.state == .error
            }) else {
                return nil
            }
            return RPCStateSnapshot.LastJob(
                jobID: job.id.uuidString,
                state: job.state,
                meetingTitle: job.meetingTitle,
                appName: job.appName,
                durationSec: Date().timeIntervalSince(job.enqueuedAt),
                transcriptPath: job.transcriptPath?.path,
                protocolPath: job.protocolPath?.path,
                error: job.error,
                warnings: job.warnings,
                participants: job.participants,
            )
        }

        /// Read live engine state. Lets `mt-cli state` (and tests) observe
        /// settings → engine propagation without running a transcription.
        private func enginesSnapshot() -> RPCStateSnapshot.Engines {
            let qwen3State: RPCStateSnapshot.Engines.Qwen3? = if #available(macOS 15, *) {
                .init(language: qwen3Engine.language)
            } else {
                nil
            }
            return RPCStateSnapshot.Engines(
                active: settings.transcriptionEngine,
                whisperKit: .init(
                    modelVariant: whisperKit.modelVariant,
                    language: whisperKit.language,
                ),
                parakeet: .init(customVocabularyPath: parakeetEngine.customVocabularyPath),
                qwen3: qwen3State,
            )
        }

        /// Closures the RPC server invokes for `/action/{rename,delete,merge}Speaker`.
        /// Same wiring as `KnownVoicesView.onMutate`: mutate the DB, then refresh
        /// the cached `knownSpeakerNames` only when the mutation actually changed
        /// state — `.notFound` paths skip the redundant disk read.
        ///
        /// The `speakerMatcherFactory` parameter exists so tests can route
        /// mutations to a temp-path `SpeakerMatcher` instead of the real
        /// `~/Library/Application Support/.../speakers.json`. Production uses
        /// the default and is unaffected.
        func makeSpeakerDBActions(
            speakerMatcherFactory: @escaping () -> SpeakerMatcher = { SpeakerMatcher() },
        ) -> SpeakerDBActions {
            SpeakerDBActions(
                rename: { [weak self] from, to in
                    let result = speakerMatcherFactory().renameSpeaker(from: from, to: to)
                    let outcome: SpeakerActionOutcome = switch result {
                    case .renamed: .ok
                    case .merged: .merged
                    case .noop: .noop
                    case .notFound: .notFound
                    }
                    if outcome != .notFound { self?.pipelineQueue.refreshKnownSpeakerNames() }
                    return outcome
                },
                delete: { [weak self] name in
                    let removed = speakerMatcherFactory().deleteSpeaker(name: name)
                    if removed { self?.pipelineQueue.refreshKnownSpeakerNames() }
                    return removed ? .ok : .notFound
                },
                merge: { [weak self] from, into in
                    let merged = speakerMatcherFactory().mergeSpeakers(from: from, into: into)
                    if merged { self?.pipelineQueue.refreshKnownSpeakerNames() }
                    return merged ? .ok : .notFound
                },
                seed: { [weak self] name in
                    let embedding = (0 ..< Self.seedEmbeddingDimension).map { _ in
                        Float.random(in: -1 ... 1)
                    }
                    speakerMatcherFactory().mutateDB { stored in
                        stored.append(StoredSpeaker(
                            name: name,
                            embeddings: [embedding],
                            centroid: embedding,
                            centroidSampleCount: 1,
                            lastUsed: Date(),
                            useCount: 1,
                            // Random vector — must never participate in
                            // auto-naming a real speaker. Filtered out by
                            // `SpeakerMatcher.matchVerbose`.
                            isSynthetic: true,
                        ))
                    }
                    self?.pipelineQueue.refreshKnownSpeakerNames()
                    return .ok
                },
            )
        }

        /// FluidAudio's diarizer emits 192-dim embeddings; seeded speakers use
        /// the same shape so they round-trip through `SpeakerMatcher` cleanly.
        /// Exposed (module-internal) so tests can assert on the shape without
        /// hardcoding the literal alongside the production source.
        static let seedEmbeddingDimension = 192
    }
#endif
