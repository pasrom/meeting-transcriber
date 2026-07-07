#if !APPSTORE
    import Foundation

    extension PermissionStatus {
        /// Stable wire string for the RPC `/state.permissionHealth` snapshot.
        var rpcValue: String {
            switch self {
            case .healthy: "healthy"
            case .denied: "denied"
            case .broken: "broken"
            case .notDetermined: "notDetermined"
            }
        }
    }

    extension PipelineQueue {
        /// Build the RPC pipeline-queue status from inside `PipelineQueue`, so the
        /// counter reads are single-hop `self.` accesses. Constructing this
        /// 4-field struct in `AppState.rpcStateSnapshot` from the two-hop
        /// `pipeline.queue.…` `@Observable` chain instead blew the type-checker up
        /// to ~100 ms (cross-type chain access + memberwise init in one body),
        /// tripping the 300 ms `-warn-long-function-bodies` budget on loaded CI
        /// runners. Self-access here type-checks in ~2 ms.
        /// `pendingNamingCount` is passed in (rather than read as
        /// `pendingSpeakerNamingJobs.count`) so the caller can reuse the count of
        /// the `pendingNamingJobs` array it already builds — one filter pass, not two.
        func rpcQueueStatus(pendingNamingCount: Int) -> RPCStateSnapshot.Pipeline {
            RPCStateSnapshot.Pipeline(
                isProcessing: isProcessing,
                activeJobCount: activeJobs.count,
                waitingJobCount: pendingJobs.count,
                pendingNamingJobCount: pendingNamingCount,
            )
        }
    }

    extension AppState {
        /// Build a snapshot of state for the debug RPC. Read-only.
        func rpcStateSnapshot() -> RPCStateSnapshot {
            let q = pipeline.queue
            let stored = SpeakerMatcher().loadDB()
            let recentNames = SpeakerMatcher.rankByRecency(speakers: stored)
                .prefix(10).map(\.name)
            let pendingJobs = q.pendingSpeakerNamingJobs.map { job in
                let data = q.speakerNamingDataByJob[job.id]
                return RPCStateSnapshot.PendingNaming(
                    jobID: job.id.uuidString,
                    meetingTitle: job.meetingTitle,
                    speakerCount: data?.mapping.count ?? 0,
                    namingSlug: job.namingSlug,
                )
            }
            return RPCStateSnapshot(
                // Built inside PipelineQueue (single-hop) to stay under the
                // type-check budget — see `rpcQueueStatus`.
                pipeline: q.rpcQueueStatus(pendingNamingCount: pendingJobs.count),
                speakerDB: .init(
                    count: stored.count,
                    recentNames: recentNames,
                    knownSpeakerNames: q.knownSpeakerNames,
                ),
                pendingNamingJobs: pendingJobs,
                engines: enginesSnapshot(),
                lastJob: lastFinishedJobSnapshot(),
                channelHealth: channelHealthSnapshot(),
                permissionHealth: permissionHealthSnapshot(),
                liveCaptions: liveCaptionsSnapshot(),
                watchState: watching.watchLoop?.state.rawValue,
                notifications: notificationsSnapshot(),
                // Built inside AppSettings (single-hop `self.` reads) to stay
                // under the type-check budget — see `rpcSettingsSnapshot`.
                settings: settings.rpcSettingsSnapshot(),
                badge: currentBadge,
            )
        }

        /// Snapshot the recently-posted notifications from the notifier this
        /// AppState was actually constructed with (the `@main` wiring passes
        /// `NotificationManager.shared`; other notifiers default to an empty log
        /// via the protocol extension) and map each entry to the wire shape with
        /// an ISO-8601 `postedAt`. Extracted (like the other `*Snapshot` helpers)
        /// to keep `rpcStateSnapshot`'s literal under the type-check budget.
        private func notificationsSnapshot() -> [RPCStateSnapshot.Notification] {
            notifier.recentNotifications.map { entry in
                RPCStateSnapshot.Notification(
                    title: entry.title,
                    body: entry.body,
                    postedAt: Self.isoFormatter.string(from: entry.postedAt),
                    delivered: entry.delivered,
                )
            }
        }

        /// Snapshot the live-caption overlay state. `LiveCaptionLine`'s
        /// `Codable` conformance encodes each entry as
        /// `{"channel": "mic"|"app", "text": …}` directly — the channel
        /// enum's raw value IS the wire format, so no mapping needed.
        private func liveCaptionsSnapshot() -> RPCStateSnapshot.LiveCaptions {
            RPCStateSnapshot.LiveCaptions(
                hypothesisMic: liveCaptions.hypothesisMic,
                hypothesisApp: liveCaptions.hypothesisApp,
                recentFinals: liveCaptions.recentFinals,
            )
        }

        /// Snapshot the channel-health flags. Extracted into a helper (rather
        /// than inlined in `rpcStateSnapshot`'s already-large literal) because
        /// reading the three `channelHealth.*` flags through the sub-controller
        /// inside that expression pushed its type-check over the 300 ms budget.
        private func channelHealthSnapshot() -> RPCStateSnapshot.ChannelHealth {
            RPCStateSnapshot.ChannelHealth(
                micSilent: channelHealth.micSilentActive,
                appSilent: channelHealth.appSilentActive,
                recordingSilent: channelHealth.recordingSilentActive,
            )
        }

        /// Snapshot the permission health verdict. `nil` before the first async
        /// check completes → `.unknown`. Extracted (like `channelHealthSnapshot`)
        /// to keep `rpcStateSnapshot`'s literal under the type-check budget.
        private func permissionHealthSnapshot() -> RPCStateSnapshot.PermissionHealth {
            guard let health = permissions.health else { return .unknown }
            return RPCStateSnapshot.PermissionHealth(
                screenRecording: health.screenRecording.rpcValue,
                microphone: health.microphone.rpcValue,
                accessibility: health.accessibility.rpcValue,
                isHealthy: health.isHealthy,
            )
        }

        /// Most recent `.done`-or-`.error` job from the queue, mapped to the
        /// snapshot shape. Used by E2E driver scripts to assert on outcome
        /// after triggering a meeting.
        private func lastFinishedJobSnapshot() -> RPCStateSnapshot.LastJob? {
            guard let job = pipeline.queue.jobs.last(where: { job in
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
            RPCStateSnapshot.Engines(
                active: settings.transcriptionEngine,
                whisperKit: .init(
                    modelVariant: engines.whisperKit.modelVariant,
                    language: engines.whisperKit.language,
                    modelState: String(describing: engines.whisperKit.modelState).lowercased(),
                ),
                parakeet: .init(
                    customVocabularyPath: engines.parakeetEngine.customVocabularyPath,
                    modelState: String(describing: engines.parakeetEngine.modelState).lowercased(),
                ),
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
                    if outcome != .notFound { self?.pipeline.queue.refreshKnownSpeakerNames() }
                    return outcome
                },
                delete: { [weak self] name in
                    let removed = speakerMatcherFactory().deleteSpeaker(name: name)
                    if removed { self?.pipeline.queue.refreshKnownSpeakerNames() }
                    return removed ? .ok : .notFound
                },
                merge: { [weak self] from, into in
                    let merged = speakerMatcherFactory().mergeSpeakers(from: from, into: into)
                    if merged { self?.pipeline.queue.refreshKnownSpeakerNames() }
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
                    self?.pipeline.queue.refreshKnownSpeakerNames()
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
