# Meeting Transcriber — macOS Architecture

## Overview

Native SwiftUI menu bar application that orchestrates meeting detection, recording, transcription, diarization, and protocol generation. Runs a background watch loop (`WatchLoop`) polling for active meetings and implementing a complete end-to-end pipeline.

**Key pattern:** Observable state models (`@Observable`) with PipelineQueue for decoupled post-processing.

---

## Pipeline

```
                ┌──────────────────────────────────────────────────┐
                │           MeetingTranscriberApp (@main)          │
                │   SwiftUI: MenuBarExtra + Settings + Naming      │
                └──────────────────────────┬───────────────────────┘
                                           │ owns
                ┌──────────────────────────▼───────────────────────┐
                │            AppState (@Observable @MainActor)     │
                │   concern controllers, settings, engines         │
                └────────┬─────────────────────────────────┬───────┘
                         │                                 │ optional
                         │                                 │ (#if !APPSTORE
                         │                                 │  + env flag)
                         │                                 ▼
                         │                  ┌──────────────────────────┐
                         │                  │  DebugRPCServer          │
                         │                  │  127.0.0.1:9876          │
                         │                  │  /state /healthz /metrics│
                         │                  │  /screenshot             │
                         │                  │  /action/openSettings    │
                         │                  │  /action/closeSettings   │
                         │                  │  /v1/* (automation API)  │
                         │                  │  Bearer-token + Origin   │
                         │                  │  reject. Driven by mt-cli│
                         │                  └──────────────────────────┘
                         │
                         ▼
                ┌─────────────────────────────────────────────────┐
                │           WatchLoop (@MainActor)                │
                │   idle → watching → recording → watching        │
                └────┬───────────────┬────────────────────┬───────┘
                     │ polls         │ starts/stops       │ enqueues
                     ▼               ▼                    ▼
        ┌─────────────────────┐  ┌────────────────┐  ┌────────────────────┐
        │ MeetingDetecting    │  │ DualSource-    │  │   PipelineQueue    │
        │  • MeetingDetector  │  │   Recorder     │  │   (@MainActor)     │
        │    (CGWindowList +  │  │                │  │                    │
        │     regex)          │  │  AudioTapLib   │  │  Sequential job    │
        │  • PowerAssertion-  │  │  (CATap +      │  │  processing →      │
        │    Detector (IOKit, │  │   AVAudioEng.) │  │  see breakdown     │
        │    sandbox-safe)    │  │  + AudioMixer  │  │  below             │
        │  • MicInputDetector │  │                │  │                    │
        │    (CoreAudio proc) │  │                │  │                    │
        └─────────────────────┘  └────────────────┘  └─────────┬──────────┘
                                                               │
        PipelineQueue per-job processing:                      │
        ┌──────────────────────────────────────────────────────▼─────────┐
        │ 1. Resample to 16 kHz mono (AudioMixer; AVAsset / ffmpeg fb)   │
        │ 2. (opt) FluidVAD silence-trim + timeline remap                │
        │ 3. Transcribe via active engine                                │
        │      └─ TranscribingEngine: WhisperKit | Parakeet             │
        │         (dual-source: each track separately, then merge)       │
        │ 4. (opt) Diarize via FluidDiarizer                             │
        │      └─ Mode: .offline | .sortformer                           │
        │      └─ Dual-source: app + mic diarized separately,            │
        │         IDs prefixed R_ (remote) / M_ (mic), then merged       │
        │ 5. SpeakerMatcher: cosine match against speakers.json          │
        │      (centroid + recent-FIFO, threshold 0.40, margin 0.10)     │
        │ 6. Speaker naming UI (suspended via CheckedContinuation)       │
        │ 7. Assign speakers to transcript by temporal overlap           │
        │ 8. Save transcript (.txt)                                      │
        │ 9. Protocol generation                                         │
        │      └─ ProtocolProvider: .claudeCLI | .openAICompatible | .none│
        │ 10. Save protocol (.md, transcript appended)                   │
        └────────────────────────────────────────────────────────────────┘
```

State writes to `AppPaths.dataDir`; IPC + queue snapshots to `ipcDir`.

---

## Source Files

### App Entry & UI

| File | Role |
|------|------|
| `MeetingTranscriberApp.swift` | `@main` UI shell — SwiftUI scenes, windows, NSOpenPanel, NSWorkspace. Observes `.showSettings` / `.closeSettings` / `.showSpeakerNaming` notifications for RPC- and pipeline-driven scene control |
| `AppState.swift` | `@Observable @MainActor` composition root — wires the concern controllers (`engines`, `watching`, `pipeline`, `permissions`, `channelHealth`, `liveTranscription`, `rpcController`) and exposes the derived UI state (badge, status label) rather than owning it |
| `MenuBarView.swift` | Menu bar dropdown (state, actions, meeting info) |
| `MenuBarIcon.swift` | Renders the animated waveform icon + badge overlays (permission, record-only, channel-silent) |
| `AppPickerView.swift` | App picker sheet for manual recording of any running app |
| `AudioImportTypes.swift` | File types offered by the batch-import and voice-enrollment `NSOpenPanel`s — single source of truth so the ffmpeg-gated vs. natively-decoded format lists stay pinned and testable |
| `A11yID.swift` | Shared accessibility-identifier namespace — one constant per control, referenced by the view modifier, ViewInspector tests, and the `/ui/press` allowlist |
| `SettingsView.swift` | Settings window — `TabView` shell hosting six topic-grouped sub-views in `Sources/Settings/` |
| `Settings/GeneralSettingsView.swift` | Mode (Record-only) · Apps to Watch (Teams/Zoom/Webex/Browser/WeChat/Tencent Meeting/FaceTime/WhatsApp) · Detection (Poll Interval, Grace Period) · Updates |
| `Settings/AudioSettingsView.swift` | Microphone device · VAD (enabled + threshold) · Per-Channel Indicator |
| `Settings/TranscriptionSettingsView.swift` | ASR engine picker · engine-specific options · model status · Live transcription (PoC) toggle |
| `Settings/SpeakersSettingsView.swift` | Diarization · Mic Speaker Name · Known Voices · Recognition Stats · Experimental Diarization Tuning |
| `Settings/OutputSettingsView.swift` | LLM provider · protocol language · output folder · custom prompt |
| `Settings/AdvancedSettingsView.swift` | Permissions · Diagnostics · About |
| `Settings/HelpBadge.swift` / `Settings/SettingsHelp.swift` | Reusable "?" help-popover badge + its shared copy, used across Settings sections |
| `Settings/View+RecordOnly.swift` | `recordOnlyDisabled(_:)` view modifier — dims + disables the Transcription/Protocol/VAD/Diarization sections when record-only mode is on |
| `SpeakerNamingView.swift` | Speaker naming dialog after diarization |
| `NamingGraceKey.swift` | Identity of one keyboard-grace window in the naming dialog — what counts as "a new grace window" (data revision + pending-job count), so the gate re-locks when another job steals focus |
| `KnownVoicesView.swift` | Manage persisted speaker DB (rename, delete, merge) — embedded in `SpeakersSettingsView` |
| `RecognitionStatsView.swift` | Recognition stats display — aggregate counts from `recognition_log.jsonl` |
| `VoiceEnrollmentView.swift` | Voice enrollment sheet — seeds `speakers.json` from an existing audio file |
| `AppSettings.swift` | `@Observable` settings persisted to UserDefaults |
| `AppSettings+Computed.swift` | Values derived from stored `AppSettings` toggles, split out to keep `AppSettings.swift` under the line cap |
| `LegacyDefaultsMigration.swift` | One-shot carry-over of settings from the pre-rename bundle identifier, since `UserDefaults` is scoped per identifier |
| `UpdateChecker.swift` | Checks GitHub releases for newer versions, drives the menu bar update badge |
| `Settings/PickerLanguages.swift` | Language picker entries for WhisperKit and Parakeet language selectors |
| `LiveCaptionsState.swift` | `@Observable` live-captions state (per-channel hypotheses + finalised utterances) + RPC-wire types |
| `LiveCaptionsOverlay.swift` | SwiftUI caption-bar content (recent finals + per-channel hypotheses) hosted in `LiveCaptionsWindow` |
| `LiveCaptionsWindowController.swift` | Borderless click-through NSPanel hosting the caption overlay (⌥-drag to reposition; origin persisted) |
| `ProcessingStatsView.swift` | Read-only average per-stage processing durations from `stage_timing.jsonl` (Settings → Advanced) |

### Core Pipeline

| File | Role |
|------|------|
| `WatchLoop.swift` | Main orchestrator: detect → record → enqueue PipelineJob |
| `WatchLoopEndPolicy.swift` | Pure decision logic for `waitForMeetingEnd` (grace-period / max-duration) |
| `WatchLoopState.swift` | Value-type snapshot of `WatchLoop`'s observable fields (for tests and RPC) |
| `ManualRecordingMonitorPolicy.swift` | Pure decision logic for manual recording stop conditions (process-died vs max-duration) |
| `MeetingDetecting.swift` | `MeetingDetecting` protocol + `DetectedMeeting` model |
| `MeetingDetector.swift` | Window title polling, pattern matching, confirmation counting, cooldown |
| `MeetingTitleMatcher.swift` | Compiled idle/meeting title regex semantics for one `AppMeetingPattern` |
| `PowerAssertionDetector.swift` | IOKit power assertion–based meeting detection (sandbox-safe); carries the Chrome WebRTC pattern for browser meetings (issue #503) |
| `MicInputDetector.swift` | Third `MeetingDetecting` strategy: watches which processes hold `kAudioProcessPropertyIsRunningInput` via the Core Audio process-object API — covers call apps (WeChat, Tencent Meeting, FaceTime, WhatsApp) with no reliable power-assertion signal; each app opt-in and off by default |
| `MeetingPatterns.swift` | Regex patterns for Teams, Zoom, Webex, browser (Chrome WebRTC) |
| `BrowserConsentPolicy.swift` | Pure decision logic for the browser-meeting "ask before recording" prompt — decline cooldown (issue #503) |
| `ConsentAnswer.swift` | Three-way outcome of a consent prompt (yes / no / unanswered) — kept distinct from a `Bool` so a decline and a timeout get different re-prompt cooldowns (issue #543) |
| `BrowserConsentReadiness.swift` | Whether a browser-meeting consent prompt can actually reach the user — polls `NotificationVisibility` since the prompt is itself a notification and a broken notification channel can't report its own brokenness |
| `ConsentPromptCoordinator.swift` | Coordinates an async yes/no recording-consent prompt: register pending decision by id, resolve once via answer or timeout |
| `WatchLoop+Consent.swift` | Browser-meeting consent gate, split out of `WatchLoop`; only patterns with `requiresRecordingConsent` reach it |
| `DualSourceRecorder.swift` | Orchestrates AudioTapLib capture + mic, mixes tracks |
| `RecordingProvider.swift` | Protocol abstraction over `DualSourceRecorder` for mock injection in `WatchLoop` tests |
| `WatchLoop+RecordOnly.swift` | Record-only output branch (moves WAVs + writes `RecordingSidecar`), split out of `WatchLoop` |
| `AudioPersistencePolicy.swift` | Decides per finished-job source file whether to relocate it into the output folder or leave it in place (staging-dir recording vs. user-picked import) |
| `TranscribingEngine.swift` | `TranscribingEngine` protocol + `mergeDualSourceSegments` default impl |
| `WhisperKitEngine.swift` | WhisperKit transcription engine (99+ languages, ~1 GB model) |
| `ParakeetEngine.swift` | NVIDIA Parakeet TDT v3 via FluidAudio (25 EU languages, ~50 MB, ~10× faster) |
| `ParakeetTokenGrouping.swift` | Pure token-grouping logic extracted from `ParakeetEngine` (testable) |
| `StreamingTranscriber.swift` | Per-channel live transcription actor (FluidVAD streaming → `engine.transcribeSamples` → partial/final captions) |
| `PipelineQueue.swift` | Decouples recording from post-processing, sequential job pipeline |
| `PipelineQueue+Stages.swift` | Per-stage job processing (transcribe → diarize → naming → protocol), split out of `PipelineQueue` (line-cap) |
| `PipelineQueue+Recovery.swift` | Snapshot restore and orphaned-recording recovery for `PipelineQueue` |
| `PipelineJob.swift` | Pipeline job model (waiting → transcribing → diarizing → generatingProtocol → done) |
| `PipelineSnapshot.swift` | Pure I/O helpers for persisting `PipelineQueue` jobs to disk (atomic rename) |
| `PipelineEventLog.swift` | Append-only JSONL log of `PipelineQueue` job state transitions |
| `StageTimingStats.swift` | Per-stage wall-clock duration tracking, backs `ProcessingStatsView` |
| `ProcessedRecordingsLedger.swift` | File-backed ledger of mix-file paths that completed the pipeline (dedupes recovery re-processing) |
| `InFlightRunRegistry.swift` | Process-wide record of currently-executing pipeline runs, so a second `PipelineQueue` built while the first is still working can't double-start the same job/audio (issue #558) |
| `SnapshotWriterActor.swift` | Actor isolating pipeline queue snapshot writes (prevents main-actor stalls on macOS 26 rename deadlock) |
| `SpeakerNamingSession.swift` | Collaborator `PipelineQueue` calls for the speaker-naming work still owned by the queue, split out for size |
| `SpeakerNamingSession+Late.swift` | Late-confirm and late re-diarization paths for speaker naming |
| `SpeakerNamingData.swift` | `PipelineQueue.SpeakerNamingData`/`.Segment`/`SpeakerNamingResult` value types, nested under `PipelineQueue` for source compat |
| `SpeakerNamingStore.swift` | Disk persistence for a job's speaker-naming sidecars, keyed by per-job slug; pure I/O, no queue state |
| `SpeakerKey.swift` | Speaker identity in the dual-track pipeline: raw diarizer id + track; single home for the `R_`/`M_` prefix convention |
| `NamingWindowPolicy.swift` | Pins the "Name Speakers" window so it stays available while the user works in other apps (issue #504) |
| `LiveTranscriptionController.swift` | Wires the per-channel live-caption pipeline (streaming or re-transcribe) to both `DualSourceRecorder` sinks (mic + app), feeds `LiveCaptionsState` |
| `LiveTranscriptionController+Nemotron.swift` | Nemotron streaming-pipeline construction, split out for size; injectable factory for testing the build + model-load-failure fallback |
| `LiveTranscriptionCoordinator.swift` | `@Observable` coordinator: builds + arms `LiveTranscriptionController`, feeds `LiveCaptionsState` |
| `LiveCaptionPipeline.swift` | Per-channel live captioning strategy protocol (English EOU streaming \| Nemotron streaming \| WhisperKit/Parakeet re-transcribe) |
| `LiveCaptionsGate.swift` | Pure decision logic for live captions routing: master toggle + explicit engine language (`en` → English EOU streaming, other → Nemotron streaming, auto-detect → re-transcribe or none) — shared by `AppState`, coordinator, and controller |
| `EouStreamingCaptionSession.swift` | English low-latency streaming caption session via FluidAudio Parakeet EOU, backed by `UtteranceRingBuffer` |
| `NemotronStreamingCaptionSession.swift` | Multilingual (non-English) low-latency streaming caption session via FluidAudio Nemotron |
| `NemotronAsrManager.swift` | Production seam wrapping FluidAudio's Nemotron model + Silero VAD for `NemotronStreamingCaptionSession` |
| `UtteranceRingBuffer.swift` | Rolling 16 kHz sample buffer addressable by absolute ms timestamp (feeds streaming caption sessions) |
| `ModelWarmupQueue.swift` | Serial FIFO gate for model warm-up loads — avoids compiling/loading the ASR engine and live-caption models concurrently at launch |
| `EngineModelState.swift` | App-owned model lifecycle state for a `TranscribingEngine`, decoupled from any ASR vendor's own enum |
| `EngineController.swift` | `@Observable @MainActor` engine selection + model lifecycle controller (language/vocabulary sync, preload) |
| `PipelineController.swift` | `@Observable` controller owning `PipelineQueue` lifecycle (wired by `AppState`) |
| `WatchingController.swift` | `@Observable` controller owning `WatchLoop` lifecycle (wired by `AppState`) |
| `WavHeaderRepair.swift` | Repairs unfinalized WAV files from crash-interrupted recordings (RIFF/data chunk size fix) |
| `FluidDiarizer.swift` | On-device speaker diarization via FluidAudio CoreML/ANE |
| `FluidDiarizer+SortformerEmbeddings.swift` | Post-hoc WeSpeaker embedding extraction for Sortformer mode — overlap-excluded masks feed `SpeakerMatcher` (DiariZen-style hybrid) |
| `SpeakerMatcher.swift` | Speaker embedding DB + cosine similarity matching |
| `SpeakerMatcher+Logging.swift` | Forensic match-decision logging (pseudonymized speaker names via `String.pseudonymized`) |
| `LiveSpeakerMatcher.swift` | Actor for real-time speaker matching per finalized live-caption utterance; same WeSpeaker CoreML model as batch path; caches mask frame count in `UserDefaults` for fast cold start |
| `StoredSpeaker.swift` | Codable speaker DB entry model (centroid + FIFO embeddings + metadata) |
| `DiarizationProcess.swift` | Diarization result types, DiarizationProvider protocol, speaker assignment (standard + dual-track) |
| `ProtocolGenerator.swift` | Shared protocol utilities: `ProtocolGenerating` protocol, prompts, file I/O, `ProtocolError` |
| `ClaudeCLIProtocolGenerator.swift` | Claude CLI subprocess protocol generation (`#if !APPSTORE`) |
| `OpenAIProtocolGenerator.swift` | OpenAI-compatible API protocol generation (Ollama, LM Studio, etc.) |
| `RecordingSidecar.swift` | Metadata sidecar written next to recordings in record-only mode |
| `RecordingFileSuffix.swift` | Filename suffix constants for dual-source recordings (`_app.wav`, `_mic.wav`, `_mix.wav`) |
| `SilentRecordingMonitor.swift` | Pure state machine detecting fully-silent recordings (both channels below threshold) |
| `ChannelHealthMonitor.swift` | Pure state machine for per-channel asymmetric silence detection (one channel live, other dead) |
| `ChannelHealthController.swift` | `@Observable` controller polling channel dBFS levels and driving `ChannelHealthMonitor` |
| `PairedImportPanelDelegate.swift` | `NSOpenPanel` delegate + accessory view for paired dual-source file import |
| `PairedRecordingResolver.swift` | Groups recording URLs into dual-source groups (app + mic pairs, singletons) for reimport |

### Audio Processing

| File | Role |
|------|------|
| `AudioMixer.swift` | Resampling, mixing, echo suppression, mute masking, WAV I/O |
| `AudioConstants.swift` | Shared audio pipeline constants (target sample rate) |
| `FFmpegHelper.swift` | ffmpeg CLI detection + 16 kHz mono WAV conversion fallback for file-import formats AVAsset can't decode |
| `MicRecorder.swift` | Microphone recording via AVAudioEngine |
| `FluidVAD.swift` | VAD preprocessing via FluidAudio Silero v6 — silence trimming + `VadSegmentMap` timeline remapping |
| `LiveAudioResampler.swift` | Streams live `LiveAudioBuffer` through `AVAudioConverter` → 16 kHz mono Float32 (feeds `StreamingTranscriber`) |
| `SampleRateDriftDetector.swift` | Watches actual vs declared CATap sample rate (catches USB hot-plug + HFP↔A2DP renegotiation drift) |
| `tools/audiotap/Sources/AppAudioCapture.swift` | CATapDescription + IOProc → FileHandle |
| `tools/audiotap/Sources/AppAudioCapture+PIDTranslation.swift` | Translates PIDs to CoreAudio `AudioObjectID`s (multi-process tap for Electron apps like Teams 2.x) |
| `tools/audiotap/Sources/AppAudioCapture+DebugLogging.swift` | Per-buffer dBFS/RMS logging helpers extracted from `AppAudioCapture` (line-cap split) |
| `tools/audiotap/Sources/AppAudioCapture+LiveSink.swift` | Live-buffer forwarding from CATap IOProc into `LiveAudioBuffer` sinks (line-cap split) |
| `tools/audiotap/Sources/AppAudioCapture+AggregateDescription.swift` | The CFDictionary describing the private aggregate device wrapping a process tap (line-cap split from `AppAudioCapture`) |
| `tools/audiotap/Sources/AppAudioCapture+Restart.swift` | Output-device-change restart path: off-main-queue, generation-tagged, deadline-bounded attempts (issue #588; line-cap split) |
| `tools/audiotap/Sources/AppTapSession.swift` | Owns one tap attempt's HAL resources (tap, aggregate device, IOProc) and their release ordering, injectable for testing without hardware |
| `tools/audiotap/Sources/MicCaptureHandler.swift` | AVAudioEngine → WAV |
| `tools/audiotap/Sources/MicCaptureHandler+Restart.swift` | Mic-side device-change restart path: off-main-queue, generation-tagged, deadline-bounded attempts (issue #588; same pattern as `AppAudioCapture+Restart`) |
| `tools/audiotap/Sources/MicEngineSession.swift` | Everything mic capture that touches `AVAudioEngine`/CoreAudio, behind a protocol so `MicCaptureHandler` is testable without hardware; one session = one engine lifetime, discarded and rebuilt on restart |
| `tools/audiotap/Sources/MicChannelMap.swift` | Decides when a discrete multi-channel mic input needs an explicit converter `channelMap` — `AVAudioConverter`'s implicit downmix silently writes digital silence for most non-stereo layouts |
| `tools/audiotap/Sources/MicConverterFactory.swift` | Builds the tap → WAV converter for one mic capture, applying `MicChannelMap`'s explicit channel selection when needed |
| `tools/audiotap/Sources/AudioCaptureSession.swift` | Orchestrator (start/stop, computes micDelay) |
| `tools/audiotap/Sources/AudioCaptureConfiguration.swift` | What one capture records and how — the single list a new capture option is added to |
| `tools/audiotap/Sources/AudioCaptureResult.swift` | Result struct |
| `tools/audiotap/Sources/LiveAudioBuffer.swift` | Real-time audio sample snapshot yielded from capture callbacks (CATap IOProc + AVAudioEngine input tap) |
| `tools/audiotap/Sources/CurrentLevel.swift` | Pure function: dBFS level read with staleness decay (stale tap → silence) |
| `tools/audiotap/Sources/LevelPublisher.swift` | Cross-thread dBFS slot: audio callback writes, UI thread reads |
| `tools/audiotap/Sources/DebugRMSReporter.swift` | Throttled RMS accumulator/reporter for audio debug logging |
| `tools/audiotap/Sources/Helpers.swift` | `machTicksToSeconds`, `getDefaultOutputDeviceUID`, `writeAllToFileHandle` |
| `tools/audiotap/Sources/MicRestartPolicy.swift` | Pure decision logic for mic engine restart on device change |
| `tools/audiotap/Sources/CaptureRestartRetryPolicy.swift` | Retry/backoff policy for a failed capture restart, shared by both the app-audio and mic channels (issue #379) |
| `tools/audiotap/Sources/RestartArbiter.swift` | Bounds how long a *single* restart attempt may run — generation-tagged so a wedged attempt that eventually returns is rejected rather than adopted, and forbids output-file creation forever once timed out (issue #588) |
| `tools/audiotap/Sources/OutputDeviceChangeCoordinator.swift` | State machine for output device change + tap restart flow |
| `tools/audiotap/Sources/ProcessTreeEnumerator.swift` | Enumerates all PIDs under an `.app` bundle (Electron/Teams child-process support) |
| `tools/audiotap/Sources/ProcessResponsibility.swift` | Groups a helper process with the app macOS holds *responsible* for it — needed for Safari, whose call audio comes from WebKit XPC services outside `Safari.app` rather than child processes under its bundle (issue #524); private symbol via `dlsym`, so it is `nil` under `APPSTORE` |
| `tools/audiotap/Sources/SystemSettingsPaths.swift` | User-facing System Settings navigation paths (e.g. Screen Recording pane, renamed in macOS 15), kept in one place so the tap-error hint, permission UI, and channel-health notification name it identically |
| `tools/audiotap/Sources/SampleRateQuery.swift` | Pure functions for sample rate detection and cross-validation |
| `tools/audiotap/Sources/AVAudioNode+SafeInstallTap.swift` | Safe `installTapOnBus` wrapper catching `NSException` via `CExceptionCatcher` (issue #379) |
| `tools/audiotap/Sources/AppAudioCapture+Resampling.swift` | Capture-time resampling for CATap buffers (line-cap split from `AppAudioCapture`) |
| `tools/audiotap/Sources/AppAudioCapture+TapError.swift` | Tap-creation error mapping (line-cap split from `AppAudioCapture`) |
| `tools/audiotap/Sources/CExceptionCatcher/` | Obj-C module catching AVFoundation `NSException` from `installTapOnBus` |
| `tools/audiotap/Sources/DebugTapFault.swift` | Fault-injection config for mic device-change E2E to verify NSException recovery |
| `tools/audiotap/Sources/MicCaptureHandler+Timeline.swift` | Timeline tracking for `MicCaptureHandler` across device-change restarts |
| `tools/audiotap/Sources/StreamingMonoResampler.swift` | Streaming mono resampler for the live 16 kHz audio path |
| `tools/audiotap/Sources/TapFormatResolver.swift` | Derives mic tap format from hardware format (prevents installTap channel-count mismatch) |
| `tools/audiotap/Sources/TimelineAnchor.swift` | Wall-clock timeline anchor across device-change restarts (keeps track aligned to real time) |

### Support

| File | Role |
|------|------|
| `TranscriberStatus.swift` | Status + state enum models |
| `AppPaths.swift` | Centralized path constants (ipcDir, dataDir, logSubsystem, speakersDB) |
| `AXHelper.swift` | Shared accessibility API helper (MuteDetector + ParticipantReader) |
| `NotificationManager.swift` | macOS notifications |
| `NotificationScheduling.swift` | Port over the `UNUserNotificationCenter` slice `NotificationManager` uses, so posting/registration is testable against a fake scheduler |
| `NotificationRingBuffer.swift` | Bounded, thread-safe log of recently-posted notifications (`#if !APPSTORE`) |
| `DateFormatter+FilenameStamp.swift` | `DateFormatter` pinned to Gregorian calendar + POSIX locale for filename timestamp stamps |
| `KeychainHelper.swift` | Legacy keychain CRUD (token now file-based) |
| `RecognitionStats.swift` | Recognition event model + `recognition_log.jsonl` reader/writer — backs `RecognitionStatsView` |
| `Permissions.swift` | Mic/accessibility permissions, project root detection |
| `PermissionRow.swift` | Permission status row UI component (icon, detail, help popover) |
| `PermissionHealthCheck.swift` | TCC verdict + live probe → `PermissionStatus`; drives exclamation badge overlay |
| `NotificationVisibility.swift` | What the notification centre will actually *do* with a posted notification (alert style, Time Sensitive, scheduled delivery) — authorisation alone can read `.authorized` while the prompt never shows |
| `ParticipantReader.swift` | Teams participant extraction via Accessibility API |
| `DebugRPCServer.swift` | Embedded HTTP RPC server core (routing, auth) for shell-driven inspection. `#if !APPSTORE`, opt-in via `MEETINGTRANSCRIBER_DEBUG_RPC=1`. Bearer-token + Origin reject; binds 127.0.0.1 only. Endpoint handlers split into companion files below (line-cap) |
| `DebugRPCServer+V1.swift` | `/v1` versioned automation API routing + response envelopes (`POST /v1/transcribe`, `/v1/jobs`, naming) |
| `DebugRPCServer+Metrics.swift` | `GET /metrics` handler — cumulative CPU/RAM/instruction counters via `proc_pid_rusage` |
| `DebugRPCServer+Screenshot.swift` | `GET /screenshot` handler (PNG of the largest visible window via ScreenCaptureKit) |
| `DebugRPCServer+UITree.swift` | `GET /ui/tree` handler — read-only accessibility tree of an allowlisted window |
| `DebugRPCServer+UIPress.swift` | `POST /ui/press` handler — presses an allowlisted control via in-process `AXUIElementPerformAction`, or via `MouseInjection` when `"via":"click"` is requested |
| `DebugRPCServer+UIType.swift` | `POST /ui/type` handler — types into an allowlisted plain-text field via `KeyboardInjection` |
| `DebugRPCServer+AXElement.swift` | Shared self-pid `AXUIElement` tree walk backing `/ui/tree` and `/ui/press` |
| `KeyboardInjection.swift` | Types text into the app's own UI via posted key events (not an AX set-value, which wouldn't fire a SwiftUI `TextField` binding) — backs `POST /ui/type` |
| `MouseInjection.swift` | Clicks a point in the app's own UI via posted mouse events (real hit-testing, unlike some `kAXPressAction` controls that report success without effect) — backs `POST /ui/press` `"via":"click"` |
| `HTTPRequest.swift` | Minimal HTTP/1.1 request parsing for `DebugRPCServer` (pure value type, line-cap split) |
| `HTTPResponse.swift` | Minimal HTTP/1.1 response serialization for `DebugRPCServer` (pure value type, line-cap split) |
| `RPCResourceMetrics.swift` | JSON-serializable resource-usage snapshot of the running process, backs `GET /metrics` |
| `JobStatusDTO.swift` | Wire + persisted shape for `GET /v1/jobs/<id>` (live or terminal job status + result paths) |
| `NamingStatusDTO.swift` | Wire shape for `GET /v1/jobs/<id>/naming` — per-speaker auto-name suggestion + speaking time + participants |
| `IdempotencyStore.swift` | Bounded FIFO map of `Idempotency-Key` → created job IDs for the `/v1` enqueue routes |
| `TerminalJobStore.swift` | File-backed store of recent finished-job statuses (survives queue reaping + app restart) |
| `AppSettings+RPC.swift` | Builds the read-only settings projection for the debug RPC `/state` endpoint |
| `AppState+RPC.swift` | Builds `RPCStateSnapshot` from live `AppState` for the `/state` endpoint (`#if !APPSTORE`) |
| `RPCStateSnapshot.swift` | JSON-serializable RPC state snapshot type (`#if !APPSTORE`) |
| `Bundle+AppVersion.swift` | Bundle extension: `appVersion` + `gitCommitHash` from `Info.plist` |
| `DiagnosticExporter.swift` | Reads log entries and writes shareable `.log` file (Settings → Advanced → Export Diagnostics) |
| `PersistentDiagnosticLog.swift` | Persistent `log stream` subprocess with sliding-window restart policy for long-term log retention |
| `String+LogRedaction.swift` | String extensions: `.pseudonymized` (SHA-256 4-hex prefix) and `.redactedName` for log privacy |
| `FileManager+OwnerOnly.swift` | `FileManager` extension: owner-only file permission constant (`rw-------`) as single source of truth |
| `SingleFlight.swift` | Single-flight async deduplication coordinator (concurrent callers await one shared run instead of starting their own) |
| `RPCServerController.swift` | `@Observable` controller owning `DebugRPCServer` lifecycle (`#if !APPSTORE`, wired by `AppState`) |
| `PermissionsController.swift` | `@Observable` controller for permission health checks (wired by `AppState`, re-runs on activation) |

### Companion CLIs

| Path | Role |
|------|------|
| `tools/mt-cli/` | Thin Swift client for `DebugRPCServer`. Subcommands: `state`, `healthz`, `screenshot`, `open-settings`, `close-settings`, `confirm-browser-consent`, `wav-verdict`, `seed-speaker`, `rename-speaker`, `delete-speaker`, `merge-speakers`, `ui-tree`, `ui-press`. Reads token from `~/Library/Application Support/MeetingTranscriber/.rpc-token`. Skill doc at `tools/mt-cli/skill.md`. |
| `tools/meeting-simulator/` | Test fixture: spawns a fake meeting window for E2E detection tests |

---

## State Machine

```
WatchLoop:     idle → watching → recording → watching (enqueues PipelineJob)
PipelineQueue: waiting → transcribing → [diarizing] → generatingProtocol → done (60s auto-remove)
                                                                            ↳ error
```

**Transitions** are observable via `WatchLoop.state` and `PipelineQueue.jobs`, triggering:
- Menu bar icon/label updates
- macOS notifications (recording started, protocol ready, error)

### Menu Bar Icon Animations

`BadgeKind.compute(watchState:queueState:permissionUnhealthy:updateAvailable:)` is the pure function that maps the combined `WatchLoop` + `PipelineQueue` state into one of `BadgeKind.inactive | .recording | .transcribing | .diarizing | .processing | .userAction | .done | .error | .updateAvailable`. `MenuBarIcon.image(badge:permissionOverlay:recordOnlyOverlay:)` then renders the matching animation frame.

| State | GIF | Triggered by | Code path |
|-------|-----|--------------|-----------|
| **Idle** | <img src="menu-bar-idle.gif" width="60"> | `WatchLoop.state == .idle / .watching` and `PipelineQueue` empty | `BadgeKind.inactive` |
| **Recording** | <img src="menu-bar-recording.gif" width="60"> | `WatchLoop.state == .recording` (waveform bars bounce) | `BadgeKind.recording` |
| **Transcribing** | <img src="menu-bar-transcribing.gif" width="60"> | `PipelineJob.state == .transcribing / .recordingDone` (bars morph into text glyphs) | `BadgeKind.transcribing` |
| **Diarizing** | <img src="menu-bar-diarizing.gif" width="60"> | `PipelineJob.state == .diarizing` (bars split into colored speaker groups) | `BadgeKind.diarizing` |
| **Protocol** | <img src="menu-bar-protocol.gif" width="60"> | `PipelineJob.state == .generatingProtocol` (lines appear sequentially) | `BadgeKind.processing` |

The icon is rendered as a SwiftUI `Image` template (auto-tinted by AppKit for light/dark mode) **unless** an overlay applies — overlays force non-template rendering to keep the colored badge intact.

### Permission problem badge

<p>
<img src="menu-bar-permission.gif" width="80" alt="Permission problem badge">
</p>

A red circle with a white "!" is composited in the bottom-right corner by `MenuBarIcon.drawExclamationBadge` whenever `PermissionHealthCheck` reports any of Microphone / Screen Recording / Accessibility as `.denied` or `.broken`. The overlay sits **on top of whatever primary state animation** is currently active — the user still sees what the app is doing while being told something is wrong. See "Permission health check + badge overlay" below for the full health-check semantics.

### Record-only mode badge

<p>
<img src="menu-bar-record-only.gif" width="80" alt="Record-only mode">
</p>

A persistent small red dot in the bottom-right corner indicates that **Record-only mode** is enabled (`AppSettings.recordOnly == true`). In this mode `WatchLoop.enqueueRecording()` moves dual-source WAVs into `<outputDir>/recordings/` together with a `<basename>_meta.json` `RecordingSidecar` and skips the entire post-processing pipeline (VAD, transcription, diarization, protocol). Intended for fleet topologies where macOS clients capture and a separate machine (e.g. a Linux GPU host via Syncthing) processes the audio. The sidecar's `trigger` field (`auto` | `manual`, schema version 2) tells that consumer which call site produced the recording, so it can treat a short auto-detected capture (likely a false trigger) differently from a short deliberate manual one.

Like the permission badge, the dot is rendered as a persistent overlay on top of whatever primary animation is currently active — so the mode is always clearly indicated whether the app is idle, recording, or running anything else. **Precedence:** when both apply, the red exclamation (permission badge) wins, because a permission problem actually breaks recording while record-only is a deliberate user choice.

### Per-channel asymmetric-silence indicator

When one capture channel goes silent while the other is still carrying audio for longer than the configured debounce window, the waveform bars in the menu bar are tinted **red** to surface the half-broken capture at a glance. `MenuBarIcon.image(..., micSilentOverlay:appSilentOverlay:)` paints the **top half** red when the mic channel is the silent one and the **bottom half** red when the app-audio channel is the silent one. When both apply, both halves are red (effectively all-red bars). Like the permission badge, this overlay forces non-template rendering so the red stays red in dark mode.

The flags driving this overlay (`AppState.micSilentActive` / `AppState.appSilentActive`) are flipped by a ~10 Hz polling task that reads `WatchLoop.activeRecorder?.{mic,app}LevelDBFS` and feeds the values into a pure `ChannelHealthMonitor` state machine. The monitor uses two dBFS thresholds — `silenceThresholdDBFS` (-60) and `speechThresholdDBFS` (-50) — with hysteresis: an episode only starts when one channel is below silence *and* the other is above speech, and only resolves when the supposedly-silent side crosses back above the speech threshold. Transient dips into the dead zone between the thresholds (natural pauses between syllables) keep the debounce timer running rather than resetting it.

Configurable in **Settings → Audio → Per-Channel Indicator**: master toggle (default on) and threshold slider (30–300 s, default 90 s). A `Capture Channel Silent` notification fires once per episode at the same moment the menu-bar tint kicks in.

**Precedence ordering** (highest wins, composes over the others underneath):

1. Permission badge (red exclamation) — actually breaks recording
2. Channel-silent tint (red waveform halves) — degraded recording
3. Record-only dot (persistent red dot) — user-chosen mode
4. Primary state animation (idle / recording / transcribing / diarizing / protocol)

---

## Audio Pipeline

### Capture

```
AudioTapLib (CATapDescription)
├─ Input: App PID → CoreAudio process tap → aggregate device
├─ Output: Interleaved float32 (mono or stereo) → FileHandle (raw PCM)
├─ Mic: AVAudioEngine → mono WAV file (MicCaptureHandler)
└─ Metadata: micDelay, actualSampleRate, actualChannels via AudioCaptureResult
```

**Key:** CATapDescription requires NO Screen Recording permission (purple dot indicator only). Handles output device changes by recreating tap automatically.

**Restart bounding (issue #588):** a device-change restart on either channel can wedge inside AVFAudio/CoreAudio and never return (e.g. `AVAudioEngine.inputNode` looping on a dangling Bluetooth sub-device held by coreaudiod). `RestartArbiter` bounds how long a single restart attempt may run — attempts carry a generation and run off the main queue, so a result from a wedged attempt that eventually returns is rejected rather than adopted. `CaptureRestartRetryPolicy` bounds how many attempts are made and is shared by both channels. A channel that gives up tells the user directly (`AudioCaptureSession`/`DualSourceRecorder` expose which one) instead of only decaying to silence, which the asymmetric-silence detector would otherwise misreport as a routing/mute problem rather than a channel that is gone for good.

**Safari support (issue #524):** the app-audio tap targets processes via macOS's *responsible-process* attribution (`ProcessResponsibility`) as well as bundle-path enumeration (`ProcessTreeEnumerator`) — Safari's call audio comes from WebKit XPC services outside `Safari.app`, unlike Electron/Chrome helpers that live inside their own bundle.

### Processing (DualSourceRecorder.stop())

```
App temp: already 16kHz mono float32 (resampled in-IOProc at capture time)
  → Save app.wav (16kHz mono)
  → Load mic.wav (already 16kHz from MicCaptureHandler)
  → Apply mute mask (zero mic during muted periods)
  → Echo suppression (RMS-based gate, 20ms windows)
  → Delay alignment (prepend zeros by MIC_DELAY)
  → Mix (average tracks)
  → Save mix.wav (16kHz mono)
```

All recordings are normalized to 16kHz at capture time — no resampling needed in the pipeline.

---

## Transcription

### Engine Selection

`TranscribingEngine` protocol abstracts ASR backends. `AppSettings.transcriptionEngine` selects the active engine.

| | WhisperKit | Parakeet TDT v3 |
|---|---|---|
| **Languages** | 99+ | 25 European |
| **Model size** | ~800 MB–1.5 GB | ~50 MB |
| **Speed (M4 Pro)** | ~10–20× RTF | ~110× RTF |
| **Language selection** | Manual or auto-detect | Auto-detect only |
| **Timestamps** | Per-segment | Per-token |
| **macOS** | 14+ | 14+ |
| **Hallucinations** | Can occur | Minimal |

### WhisperKit Engine

- **Model:** `openai_whisper-large-v3-v20240930_turbo` (CoreML/ANE)
- **Pre-loading:** Model downloaded and loaded at app launch (when selected)
- **Lazy fallback:** `ensureModel()` loads on-demand if not ready

### Parakeet Engine

- **Model:** NVIDIA Parakeet TDT v3 via FluidAudio (CoreML/ANE)
- **Pre-loading:** Model downloaded and loaded at app launch (when selected)
- **Token grouping:** `groupTokensIntoSegments` groups per-token timings into sentence-level segments (split on `. ! ?` or 20 tokens)

### Modes

1. **Single source:** `transcribeSegments(audioPath:)` → `[TimestampedSegment]` with start/end/text
2. **Dual source:** `transcribeSegments(appAudio:)` + `transcribeSegments(micAudio:)` → `mergeDualSourceSegments(appSegments:micSegments:)` → `[TimestampedSegment]` merged by timestamp
   - App segments labeled "Remote"
   - Mic segments labeled with user's mic name (default "Me")
   - `mergeDualSourceSegments` is a protocol extension on `TranscribingEngine` — shared by all engines

### Post-processing (WhisperKit only)

- **Token stripping:** Regex `<\|[^|]*\|>` removes `<|startoftranscript|>`, `<|en|>`, etc.
- **Hallucination filtering:** Skip consecutive identical segments

---

## Live Captions (PoC)

Optional in-meeting caption overlay, "Show partial transcripts during recording" in Settings →
Transcribe (`AppSettings.liveTranscriptionEnabled`, off by default; enabling downloads a ~0.6 GB
model on first use behind a consent alert).

`LiveCaptionsGate.strategy(liveEnabled:engineLanguage:engineSupportsLive:)` is the pure decision
function — shared by `AppState`, `LiveTranscriptionCoordinator`, and `LiveTranscriptionController`
— that picks the per-channel backend from the active engine's **explicitly configured** language
(not auto-detect):

| Engine language | Strategy | Backend |
|---|---|---|
| `en` | English streaming | `EouStreamingCaptionSession` (FluidAudio Parakeet EOU) |
| any other explicit language | Nemotron streaming | `NemotronStreamingCaptionSession` / `NemotronAsrManager` (FluidAudio Nemotron multilingual) |
| auto-detect (`nil`) | re-transcribe | `StreamingTranscriber` via the active engine's `transcribeSamples`, if supported |
| auto-detect + engine doesn't support live re-transcribe | none | captions off |

Both streaming sessions are engine-independent (they drive their own FluidAudio models directly),
so they're available even when the active `TranscribingEngine` has no live re-transcribe hook.
`LiveTranscriptionController` wires the resolved per-channel pipeline to both `DualSourceRecorder`
sinks (mic + app) and feeds `LiveCaptionsState`, which backs the `LiveCaptionsOverlay` window.
`ModelWarmupQueue` serializes model warm-up loads (ASR engine + streaming models) so they don't
compile/load concurrently at launch.

---

## Diarization

### FluidDiarizer (On-device)

On-device speaker diarization using FluidAudio (CoreML/ANE). No HuggingFace token or Python subprocess needed. Models downloaded automatically on first run (~50 MB).

Two modes selected via `AppSettings.diarizerMode`:
- **`.offline`** (default) — `OfflineDiarizerManager`, standard speaker segmentation
- **`.sortformer`** — `SortformerDiarizer`, overlap-aware diarization (handles simultaneous speech); speaker embeddings extracted post-hoc via `FluidDiarizer+SortformerEmbeddings` using overlap-excluded WeSpeaker masks

Flow: `FluidDiarizer.run(audioPath, numSpeakers)` → selected diarizer → `DiarizationResult` with segments, speaking times, and speaker embeddings.

**Experimental tuning:** Five `OfflineDiarizerConfig` parameters are exposed in `AppSettings` and editable in Settings → Speakers → Experimental Diarization Tuning: `clusterThreshold` (0.6), `warmStartFa` (0.07), `warmStartFb` (0.8), `minSegmentDurationSeconds` (1.0), `excludeOverlap` (true). All default to FluidAudio community values.

### Speaker Matching

`SpeakerMatcher` matches diarization speaker embeddings against a persistent speaker database (`speakers.json`) using cosine similarity (threshold: 0.40, confidence margin: 0.10). Stores a running-mean centroid (primary match anchor) plus a recent-samples FIFO (max 3, fallback when centroid match is borderline). Quality filter: embeddings from segments shorter than 3 s are excluded from the centroid but kept as fallback samples. Speakers are ranked by recency and use count in the naming UI. Enables recognition of returning speakers across meetings.

### Speaker Assignment

For each transcript segment, find the diarization segment with the longest temporal overlap:
```
overlap = max(0, min(seg.end, dSeg.end) - max(seg.start, dSeg.start))
```
No overlap → nearest-segment fallback by gap distance. Only if no diarization segments exist → "UNKNOWN".

### Dual-Track Diarization

When dual-source recording (app + mic) is available:
1. Transcribe app/mic tracks separately → "Remote" / micLabel segments
2. Diarize app track and mic track separately via FluidAudio
3. `mergeDualTrackDiarization()` — prefix speaker IDs (`R_` for remote, `M_` for local), merge segments by time
4. `preMatchParticipants()` — heuristic assignment of Teams participants to unmatched speakers by speaking time
5. Speaker naming UI — all speakers editable with participant suggestions
6. `assignSpeakersDualTrack()` — app segments matched against app diarization, mic segments against mic diarization

**Single-source fallback:** When only mix audio is available, diarize the mix and use `assignSpeakers()` with nearest-segment fallback.

### Speaker Naming UI

`SpeakerNamingView` shown when diarization finds speakers. Each row shows label, auto-matched name, speaking time, and audio playback. All rows are editable. Supports re-run with different speaker count.

---

## Protocol Generation

### Provider Selection

`AppSettings.protocolProvider` selects the active provider:
- **`.claudeCLI`** — Claude CLI subprocess (`#if !APPSTORE`)
- **`.openAICompatible`** — Any OpenAI-compatible HTTP API (Ollama, LM Studio, llama.cpp, etc.)
- **`.none`** — Skip LLM generation; save transcript only

`AppSettings.protocolLanguage` (default `"German"`) is substituted into the prompt as `{LANGUAGE}`. Custom prompts can also use `{MEETING_DATE}` (`YYYY-MM-DD`) and `{MEETING_TIME}` (`HH:mm`), derived from the meeting start time. Every protocol request additionally starts with an authoritative meeting-metadata block, so existing custom prompts receive temporal context without needing to add the placeholders.

### Claude CLI Invocation

```bash
/usr/bin/env claude -p - --output-format stream-json --verbose --model sonnet
```

- **Input:** Meeting metadata + protocol prompt (with variables substituted) + transcript piped to stdin
- **Output:** Stream-json parsed line-by-line (content_block_delta + assistant message)
- **Environment:** `CLAUDECODE` env var stripped to allow nested invocation
- **Timeout:** 10 minutes

### Output Structure

```markdown
# Meeting Protocol - [Title]
## Summary
## Participants
## Topics Discussed
## Decisions
## Tasks (table)
## Open Questions

---

## Full Transcript
[appended automatically]
```

---

## Data Flow

### Observable State Propagation

```
AppSettings (UserDefaults)
  → WatchLoop (@Observable: state, detail, currentMeeting, lastError)
  → PipelineQueue (@Observable: jobs, isProcessing, pendingSpeakerNaming)
    → AppState (computed: currentBadge via BadgeKind.compute(), currentStatus, currentStateLabel)
      → MeetingTranscriberApp (reads appState.*, passes to views)
        → MenuBarView (receives status + callbacks + pipeline queue)
        → SettingsView (receives @Bindable settings)
        → SpeakerNamingView (receives pendingSpeakerNaming data)
```

### File Locations

| Content | Path |
|---------|------|
| Recordings | `~/Library/Application Support/MeetingTranscriber/recordings/` |
| Protocols | `~/Library/Application Support/MeetingTranscriber/protocols/` |
| IPC | `~/.meeting-transcriber/` |
| Speaker DB | `~/Library/Application Support/MeetingTranscriber/speakers.json` |
| Pipeline logs | `~/.meeting-transcriber/pipeline_queue.json`, `pipeline_log.jsonl` |
| AudioTapLib | Linked as SPM library (no separate binary) |

---

## Testing Hooks

| Component | Injection Point |
|-----------|----------------|
| MeetingDetector | `windowListProvider` closure (mock window list) |
| PowerAssertionDetector | `assertionProvider` + `windowListProvider` closures |
| MicInputDetector | `processProvider` + `windowListProvider` closures |
| DiarizationProvider | `diarizationFactory` closure in PipelineQueue |
| ProtocolGenerating | `protocolGenerator` protocol in PipelineQueue |
| RecordingProvider | `recorderFactory` closure in WatchLoop |
| ProtocolGenerator | `claudeBin` parameter |
| NotificationManager | `NotificationScheduling` port over `UNUserNotificationCenter` (fake scheduler in tests) |
| ConsentPromptCoordinator | Injected timeout clock; pure register/resolve-once API (no UI dependency) |
| LiveCaptionsGate.strategy | Pure static function — call directly with any input combination, no controller needed |
| AppNotifying | `notifier` parameter in `AppState.init` (`SilentNotifier` default, `RecordingNotifier` in tests) |
| BadgeKind.compute | Pure static function — call directly with any input combination, no WatchLoop needed |
| DebugRPCServer | Out-of-process inspection via HTTP. Debug endpoints: `GET /state /healthz /metrics /screenshot`, `POST /action/openSettings /action/closeSettings`. Versioned automation API under `/v1` (`POST /v1/transcribe`, `POST /v1/jobs`, `GET /v1/jobs/<id>`, `GET`/`POST /v1/jobs/<id>/naming`, `POST /v1/jobs/<id>/naming/skip`); see `docs/automation-api.md`. `#if !APPSTORE` + env-gated. `boundPort` exposes OS-assigned port for in-process integration tests. `tools/mt-cli/` is the matching inspection CLI. `scripts/test_rpc.sh` is a live smoketest (build + launch + drive + assert). |

---

## Permissions

| Permission | Required For | Notes |
|------------|-------------|-------|
| Screen Recording | Meeting detection (window titles) | CGWindowListCopyWindowInfo |
| Microphone | Mic recording | AVAudioEngine |
| Accessibility | Mute detection, participant reading | Teams AX tree |
| None | App audio capture | CATapDescription (purple dot only) |

### Permission health check + badge overlay

`PermissionHealthCheck` verifies each of the three TCC permissions by combining the system verdict with a live probe (e.g. `CGWindowListCopyWindowInfo` returning non-empty window titles for Screen Recording). Each permission resolves to `PermissionStatus.healthy | .denied | .broken | .notDetermined` — `.broken` means "TCC says allowed but the probe disagrees," which happens when macOS hasn't actually wired the permission through and the user needs to toggle it off and on in System Settings.

`WatchLoop` runs the check on startup and `AppState` re-runs it on app activation. When the result is unhealthy:

1. `MeetingTranscriberApp` passes `permissionOverlay: true` to `MenuBarIcon.image(...)`, which composites a red circle with a white "!" in the bottom-right corner over the current badge (`MenuBarIcon.drawExclamationBadge`). This bypasses the cached template icons and renders a non-template image because the overlay must stay red in both light and dark mode.
2. `BadgeKind.compute(...)` returns `.error` when idle-with-problem, so the icon also reflects the problem state when no job is active.
3. A notification is posted via `NotificationManager` with the list of affected permissions (deduplicated — only re-posted when the problem set actually changes).

The overlay lives over the *currently active* animation (idle, recording, transcribing, …) so the user still sees what the app is doing and is simultaneously told "one of the permissions is wrong."

<p>
<img src="menu-bar-permission.gif" width="80" alt="Permission problem badge">
</p>

---

## Settings UI

`SettingsView` is a thin `TabView` shell. Each tab is a self-contained `View` in `Sources/Settings/` owning only the bindings it needs and its own local `@State`. The settings window is resizable (`minWidth: 620, idealWidth: 720, maxWidth: 900`).

| Tab | Sections | Bindings | Local state |
|---|---|---|---|
| **General** | Apps to Watch · Detection · Updates | `settings`, `updateChecker?` | — |
| **Audio** | Microphone · VAD | `settings` | `audioDevices` |
| **Transcription** | Engine + per-engine options + status | `settings`, three engines | — |
| **Speakers** | Diarization · Speaker Identity · Known Voices · Recognition Stats · Experimental Diarization Tuning | `settings`, `recognitionStatsLog`, `enrollmentDiarizerFactory` | `knownVoicesSheet` |
| **Output** | LLM Provider · Protocol Language · Output Folder · Prompt | `settings` | `claudeBinaries` (#if !APPSTORE), connection-test state, `availableModels`, `hasCustomPrompt` |
| **Advanced** | Permissions · Diagnostics · About | — | `micPermission`, `screenRecordingOK`, `accessibilityOK` |

**Conditional rendering rules:**
- `noMic` hides the mic-device picker (Audio) and the Speaker Identity section (Speakers)
- `diarize` hides the diarizer-mode picker and Expected Speakers stepper
- `vadEnabled` hides the VAD threshold slider
- `transcriptionEngine` switches between WhisperKit / Parakeet option panels
- `protocolProvider` switches between Claude CLI / OpenAI-compatible / None panels
- `#if APPSTORE` removes the Claude CLI provider option entirely
- `updateChecker == nil` hides the entire Updates section

**Cross-cutting concerns owned by sub-views:**
- `OutputSettingsView` owns OpenAI-endpoint connection testing (`testConnection()`) and custom-prompt I/O (`openCustomPrompt`, `importCustomPrompt`, reset confirmation)
- `AdvancedSettingsView` owns permission live-probing (`refreshPermissions()`) and version/build/ffmpeg status

---

## Key Architectural Decisions

1. **@Observable over @StateObject** — Fine-grained reactivity, macOS 14+
2. **PipelineQueue decoupling** — Recording and post-processing run independently; WatchLoop enqueues jobs and resumes watching
3. **AudioTapLib as SPM library** — Direct in-process audio capture via CATapDescription (App Store compatible)
4. **Dual-source recording** — Enables speaker separation without diarization (app=Remote, mic=Me)
5. **Graceful degradation** — Diarization optional, mute detection optional, continues on partial failure
6. **Pre-loaded model** — Selected engine (WhisperKit or Parakeet) loaded at app launch, prevents delay on first meeting
7. **5s cooldown** — Prevents re-detecting same meeting after handling
8. **FluidAudio on-device diarization** — Replaces Python pyannote subprocess, no external dependencies
9. **Dual-track diarization** — App and mic tracks diarized separately, avoiding echo/cross-talk interference
10. **Embedded debug RPC + automation API** — In-process HTTP server (`DebugRPCServer`) exposes state, resource metrics (`GET /metrics`), screenshot, and scene actions for shell-driven inspection and integration tests, plus a versioned `/v1` automation API (headless transcribe + job/naming control; reference in `docs/automation-api.md`). Off by default, opt-in via the `Settings → Advanced → Local Automation API` toggle or the `MEETINGTRANSCRIBER_DEBUG_RPC=1` env var, excluded from App Store builds via `#if !APPSTORE`. Action endpoints route through existing `Notification.Name` observers in `MeetingTranscriberApp`, so RPC-driven flows mirror real menu-bar paths.
11. **No expensive work in SwiftUI hot paths** — view bodies, computed properties read by the body, and per-render closures must not call disk I/O, JSON decode, factory constructors, regex compilation, or other non-trivial work. SwiftUI re-renders on every `@State`/`@Observable` change and fans out aggressively, so what looks cheap once becomes a CPU pin fast. Push heavy values up: store as `@State`, inject as a stored property, or surface via an `@Observable` model. Caches that mirror the underlying source (e.g. `PipelineQueue.knownSpeakerNames` mirroring the speakers DB) must wire invalidation from every mutation site in the same PR — see issue #155 → PR #158 → PR #159 for the cautionary tale.
