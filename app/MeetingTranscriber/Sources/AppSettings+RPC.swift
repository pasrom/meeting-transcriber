#if !APPSTORE
    import Foundation

    extension AppSettings {
        /// Build the read-only settings projection for the debug RPC `/state`
        /// snapshot from inside `AppSettings`, so every field read is a
        /// single-hop `self.` access. Assembling it in `AppState.rpcStateSnapshot`
        /// from the two-hop `state.settings.…` `@Observable` chain instead risks
        /// the 300 ms CI type-check budget (`-warn-long-function-bodies`, treated
        /// as an error) — same precedent as `PipelineQueue.rpcQueueStatus`. Each
        /// sub-object is built by its own small helper so no single expression
        /// approaches the per-expression budget either.
        ///
        /// SECRETS ARE EXCLUDED BY CONSTRUCTION: `openAIAPIKey` (Keychain-backed)
        /// and any other secret are never read here. Only non-secret scalars,
        /// enum raw values, and paths are exposed. This is the localhost,
        /// token-authed debug surface that already exposes job titles and
        /// screenshots, so home-directory paths are acceptable; secrets are not.
        func rpcSettingsSnapshot() -> RPCStateSnapshot.Settings {
            RPCStateSnapshot.Settings(
                detection: rpcDetectionSettings(),
                recording: rpcRecordingSettings(),
                transcription: rpcTranscriptionSettings(),
                diarization: rpcDiarizationSettings(),
                protocolGeneration: rpcProtocolSettings(),
                output: rpcOutputSettings(),
                diagnostics: rpcDiagnosticsSettings(),
                updates: rpcUpdatesSettings(),
            )
        }

        private func rpcDetectionSettings() -> RPCStateSnapshot.Settings.Detection {
            RPCStateSnapshot.Settings.Detection(
                watchTeams: watchTeams,
                watchZoom: watchZoom,
                watchWebex: watchWebex,
                autoWatch: autoWatch,
                pollIntervalSeconds: pollInterval,
            )
        }

        private func rpcRecordingSettings() -> RPCStateSnapshot.Settings.Recording {
            RPCStateSnapshot.Settings.Recording(
                endGraceSeconds: endGrace,
                noMic: noMic,
                recordOnly: recordOnly,
                micDeviceUID: micDeviceUID,
                micName: micName,
                perChannelIndicatorEnabled: perChannelIndicatorEnabled,
                liveTranscriptionEnabled: liveTranscriptionEnabled,
                asymmetricSilenceWarningSeconds: asymmetricSilenceWarningSeconds,
            )
        }

        private func rpcTranscriptionSettings() -> RPCStateSnapshot.Settings.Transcription {
            RPCStateSnapshot.Settings.Transcription(
                engine: transcriptionEngine.rawValue,
                whisperKitModel: whisperKitModel,
                whisperLanguage: whisperLanguage,
                parakeetLanguage: parakeetLanguage,
                customVocabularyPath: customVocabularyPath,
            )
        }

        private func rpcDiarizationSettings() -> RPCStateSnapshot.Settings.Diarization {
            RPCStateSnapshot.Settings.Diarization(
                diarize: diarize,
                mode: diarizerMode.rawValue,
                numSpeakers: numSpeakers,
                vadEnabled: vadEnabled,
                vadThreshold: vadThreshold,
                clusterThreshold: clusterThreshold,
                warmStartFa: warmStartFa,
                warmStartFb: warmStartFb,
                minSegmentDurationSeconds: minSegmentDurationSeconds,
                excludeOverlap: excludeOverlap,
            )
        }

        private func rpcProtocolSettings() -> RPCStateSnapshot.Settings.ProtocolGeneration {
            RPCStateSnapshot.Settings.ProtocolGeneration(
                provider: protocolProvider.rawValue,
                language: protocolLanguage,
                openAIEndpoint: openAIEndpoint,
                openAIModel: openAIModel,
                claudeBin: claudeBin,
            )
        }

        private func rpcOutputSettings() -> RPCStateSnapshot.Settings.Output {
            RPCStateSnapshot.Settings.Output(
                directory: rpcOutputDirPath(),
                hasCustomDirectory: customOutputDirBookmark != nil,
                hasCustomPrompt: FileManager.default.fileExists(atPath: AppPaths.customPromptFile.path),
            )
        }

        /// Read-only, fail-fast resolution of the effective output dir for the
        /// snapshot. Deliberately NOT `effectiveOutputDir`: that resolves the
        /// bookmark with `.withSecurityScope`, which can block the main actor
        /// while a detached network volume is contacted (the RPC snapshot runs
        /// MainActor-isolated on every `GET /state` poll), and on a stale
        /// bookmark it WRITES a re-created bookmark back to UserDefaults, a
        /// persisted mutation from a read-only debug GET. Here we resolve with
        /// `.withoutUI`/`.withoutMounting` (fails fast instead of mounting),
        /// ignore staleness, and report nil when the custom dir is currently
        /// unresolvable.
        private func rpcOutputDirPath() -> String? {
            guard let data = customOutputDirBookmark else {
                return AppPaths.downloadsProtocolsDir.path
            }
            var isStale = false
            guard let url = try? URL(
                resolvingBookmarkData: data,
                options: [.withoutUI, .withoutMounting],
                relativeTo: nil,
                bookmarkDataIsStale: &isStale,
            ) else { return nil }
            return url.path
        }

        private func rpcDiagnosticsSettings() -> RPCStateSnapshot.Settings.Diagnostics {
            RPCStateSnapshot.Settings.Diagnostics(
                verboseDiagnostics: verboseDiagnostics,
                debugRPCEnabled: debugRPCEnabled,
            )
        }

        private func rpcUpdatesSettings() -> RPCStateSnapshot.Settings.Updates {
            RPCStateSnapshot.Settings.Updates(
                checkForUpdates: checkForUpdates,
                includePreReleases: includePreReleases,
            )
        }
    }
#endif
