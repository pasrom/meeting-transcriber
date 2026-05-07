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
            )
        }

        /// Closures the RPC server invokes for `/action/{rename,delete,merge}Speaker`.
        /// Same wiring as `KnownVoicesView.onMutate`: mutate the DB, then refresh
        /// the cached `knownSpeakerNames` only when the mutation actually changed
        /// state — `.notFound` paths skip the redundant disk read.
        func makeSpeakerDBActions() -> SpeakerDBActions {
            SpeakerDBActions(
                rename: { [weak self] from, to in
                    let result = SpeakerMatcher().renameSpeaker(from: from, to: to)
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
                    let removed = SpeakerMatcher().deleteSpeaker(name: name)
                    if removed { self?.pipelineQueue.refreshKnownSpeakerNames() }
                    return removed ? .ok : .notFound
                },
                merge: { [weak self] from, into in
                    let merged = SpeakerMatcher().mergeSpeakers(from: from, into: into)
                    if merged { self?.pipelineQueue.refreshKnownSpeakerNames() }
                    return merged ? .ok : .notFound
                },
                seed: { [weak self] name in
                    let embedding = (0 ..< Self.seedEmbeddingDimension).map { _ in
                        Float.random(in: -1 ... 1)
                    }
                    SpeakerMatcher().mutateDB { stored in
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
        private static let seedEmbeddingDimension = 192
    }
#endif
