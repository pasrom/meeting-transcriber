# Meeting Transcriber

## Project Structure

```
VERSION                    # App version (read by build scripts)
app/MeetingTranscriber/    # Swift macOS menu bar app (SPM)
  Package.swift            # SPM manifest (WhisperKit + FluidAudio + AudioTapLib runtime deps; ViewInspector + SnapshotTesting test deps)
  Sources/
    MeetingTranscriberApp.swift  # @main, UI shell (scenes, NSOpenPanel, NSWorkspace)
    AppState.swift         # @Observable @MainActor composition root: wires the concern controllers (engines/watching/pipeline/permissions/channelHealth/liveTranscription/rpc) + exposes derived UI props (badge, status label)
    AppState+RPC.swift     # RPC state snapshot helper for DebugRPCServer (#if !APPSTORE)
    EngineController.swift   # @Observable @MainActor engine selection + model lifecycle controller (language/vocabulary sync, preload)
    AudioConstants.swift   # Shared audio pipeline constants (target sample rate)
    MenuBarView.swift      # Menu bar dropdown UI
    MenuBarIcon.swift      # Animated waveform menu bar icon + BadgeKind.compute() pure function
    ChannelHealthMonitor.swift  # Pure state machine for per-channel asymmetric silence detection (mic vs app audio)
    ChannelHealthController.swift  # @Observable controller polling channel levels and driving ChannelHealthMonitor
    SettingsView.swift     # Settings window (TabView shell hosting six sub-views in Settings/)
    Settings/
      GeneralSettingsView.swift  # Apps to Watch · Detection · Updates
      AudioSettingsView.swift    # Microphone device · VAD settings
      TranscriptionSettingsView.swift  # ASR engine picker + per-engine options
      SpeakersSettingsView.swift # Diarization · Mic Speaker Name · Known Voices · Recognition Stats
      OutputSettingsView.swift   # LLM provider · protocol language · output folder · prompt
      AdvancedSettingsView.swift # Permissions · Diagnostics · About
      View+RecordOnly.swift      # `recordOnlyDisabled(_:)` SwiftUI modifier (dim + disable downstream sections)
      PickerLanguages.swift      # Language picker entries for WhisperKit, Parakeet, and Qwen3 language selectors
    SpeakerNamingView.swift # Speaker naming dialog + AccessibleTextField
    KnownVoicesView.swift  # Speaker DB management UI (rename, delete, merge entries)
    RecognitionStatsView.swift # Recognition stats display (aggregate counts from recognition_log.jsonl)
    VoiceEnrollmentView.swift  # Voice enrollment sheet (seed speakers.json from audio file)
    AppPickerView.swift    # App picker for manual recording
    LiveCaptionsState.swift # @Observable live-captions state (per-channel hypotheses + finalised utterances) + RPC-wire types
    LiveCaptionsOverlay.swift # SwiftUI caption-bar content (recent finals + per-channel hypotheses) hosted in LiveCaptionsWindow
    LiveCaptionsWindowController.swift # Borderless click-through NSPanel hosting the caption overlay (⌥-drag to reposition; origin persisted)
    LiveCaptionPipeline.swift # Per-channel live captioning strategy protocol (WhisperKit word-level | EOU streaming)
    LiveCaptionsGate.swift   # Pure decision logic for live captions routing (which pipeline per channel, shared by AppState + controller)
    EouStreamingCaptionSession.swift # EOU streaming caption session (FluidAudio end-of-utterance ASR, UtteranceRingBuffer-backed)
    UtteranceRingBuffer.swift # Rolling 16 kHz sample buffer addressable by absolute timestamp (feeds EOU streaming)
    PairedImportPanelDelegate.swift  # NSOpenPanel delegate + accessory view for paired dual-source file import
    PairedRecordingResolver.swift    # Groups recording URLs into dual-source groups for reimport
    AppPaths.swift         # Centralized paths (ipcDir, dataDir, logSubsystem, speakersDB)
    AppSettings.swift      # @Observable settings (UserDefaults + file-based secrets)
    AXHelper.swift         # Shared accessibility API helper
    NotificationManager.swift # macOS notifications
    KeychainHelper.swift   # Keychain CRUD (legacy/test-only, token now file-based)
    TranscriberStatus.swift # Status + MeetingInfo models
    TranscribingEngine.swift # TranscribingEngine protocol + mergeDualSourceSegments default impl
    WhisperKitEngine.swift # WhisperKit transcription engine (CoreML/ANE, 99+ languages)
    ParakeetEngine.swift   # NVIDIA Parakeet TDT v3 engine via FluidAudio (CoreML/ANE, 25 EU languages)
    ParakeetTokenGrouping.swift  # Pure token-grouping logic extracted from ParakeetEngine (testable)
    Qwen3AsrEngine.swift   # Qwen3-ASR 0.6B engine via FluidAudio (CoreML/ANE, 30 languages, macOS 15+)
    Qwen3AsrChunking.swift  # Pure audio chunking logic extracted from Qwen3AsrEngine (testable)
    StreamingTranscriber.swift # Per-channel live transcription actor (FluidVAD streaming → engine.transcribeSamples → partial/final captions)
    FluidDiarizer.swift    # CoreML-based speaker diarization via FluidAudio (on-device, OfflineDiarizer + Sortformer modes)
    FluidDiarizer+SortformerEmbeddings.swift  # Post-hoc WeSpeaker embedding extraction for Sortformer mode (feeds SpeakerMatcher)
    FluidVAD.swift         # VAD preprocessing via FluidAudio Silero v6 (silence trimming + timeline remapping)
    SpeakerMatcher.swift   # Speaker embedding DB + cosine similarity matching
    SpeakerMatcher+Logging.swift # Forensic match-decision logging (pseudonymized speaker names)
    LiveSpeakerMatcher.swift  # Actor for real-time speaker matching in live captions overlay (same WeSpeaker model as batch path)
    StoredSpeaker.swift    # Codable speaker DB entry model (centroid + FIFO embeddings + metadata)
    RecognitionStats.swift # Recognition event logging + aggregate stats model (recognition_log.jsonl)
    RecordingSidecar.swift # Metadata sidecar written next to dual-source recordings in record-only mode
    RecordingFileSuffix.swift  # Filename suffixes for dual-source recordings (_app.wav, _mic.wav, _mix.wav)
    DiarizationProcess.swift  # DiarizationProvider protocol + result types
    PipelineQueue.swift    # Decouples recording from post-processing (transcription → diarization → protocol)
    PipelineJob.swift      # Pipeline job model
    PipelineSnapshot.swift  # Pure I/O helpers for persisting pipeline queue jobs to disk (atomic rename)
    SnapshotWriterActor.swift  # Actor isolating pipeline queue snapshot writes (prevents main-actor stalls)
    PipelineController.swift  # @Observable controller owning PipelineQueue lifecycle (wired by AppState)
    LiveTranscriptionController.swift # Wires StreamingTranscriber to both DualSourceRecorder sinks (mic + app), feeds LiveCaptionsState (PoC)
    LiveTranscriptionCoordinator.swift # @Observable coordinator: builds + arms LiveTranscriptionController, feeds LiveCaptionsState
    ProtocolGenerator.swift   # Shared protocol utilities: prompts, file I/O, ProtocolError
    ClaudeCLIProtocolGenerator.swift # Claude CLI subprocess protocol generation (#if !APPSTORE)
    OpenAIProtocolGenerator.swift # OpenAI-compatible API protocol generation (Ollama, LM Studio, etc.)
    WatchLoop.swift        # @MainActor watch loop: detect → record → enqueue PipelineJob
    WatchLoopEndPolicy.swift  # Pure decision logic for WatchLoop.waitForMeetingEnd (grace-period / max-duration)
    WatchLoopState.swift   # Value-type snapshot of WatchLoop's observable fields (for tests and RPC)
    WatchingController.swift  # @Observable controller owning WatchLoop lifecycle (wired by AppState)
    ManualRecordingMonitorPolicy.swift  # Pure decision logic for manual recording stop conditions (process-died vs max-duration)
    SilentRecordingMonitor.swift  # Pure state machine detecting fully-silent recordings (both channels below threshold)
    DualSourceRecorder.swift  # App audio (AudioTapLib) + mic recording (captures startTime in start())
    WavHeaderRepair.swift     # Repairs unfinalized WAV files from crash-interrupted recordings (RIFF/data chunk size fix)
    MeetingDetecting.swift # MeetingDetecting protocol + DetectedMeeting model
    MeetingDetector.swift  # Window title matching (counts each pattern once per poll)
    FFmpegHelper.swift     # ffmpeg CLI detection + audio extraction for MKV/WebM/OGG
    AudioMixer.swift       # Multi-format audio loading (WAV/MP3/M4A/MP4 via AVAsset fallback, MKV/WebM/OGG via ffmpeg) + mixing to 16kHz mono
    LiveAudioResampler.swift # Streams live LiveAudioBuffer through AVAudioConverter → 16 kHz mono Float32 (feeds StreamingTranscriber)
    SampleRateDriftDetector.swift # Watches actual vs declared CATap sample rate (catches USB hot-plug + HFP↔A2DP renegotiation drift)
    MicRecorder.swift      # Microphone recording via AVAudioEngine
    PermissionHealthCheck.swift # Permission health check (TCC verdict + live probe → PermissionStatus)
    PermissionsController.swift # @Observable controller for permission health checks (wired by AppState)
    PermissionRow.swift    # Permission status row UI component
    Permissions.swift      # Permission checks (mic, screen recording)
    ParticipantReader.swift # Reads meeting participants via accessibility
    MeetingPatterns.swift  # App-specific window title patterns
    PowerAssertionDetector.swift  # Meeting detection via IOKit power assertions (sandbox-safe)
    UpdateChecker.swift    # GitHub release update checker
    Bundle+AppVersion.swift # Bundle extension: appVersion + gitCommitHash from Info.plist
    FileManager+OwnerOnly.swift # FileManager extension: owner-only file permission constant (rw-------, single source of truth)
    SingleFlight.swift        # Single-flight async deduplication coordinator (concurrent callers await one shared run)
    DiagnosticExporter.swift # Reads log entries → shareable .log file (Settings → Advanced → Export Diagnostics)
    PersistentDiagnosticLog.swift # Persistent log stream subprocess with sliding-window restart policy
    String+LogRedaction.swift # String extensions: .pseudonymized and .redactedName for log privacy
    DebugRPCServer.swift   # Localhost HTTP RPC for shell-driven inspection (#if !APPSTORE, env-gated by MEETINGTRANSCRIBER_DEBUG_RPC=1)
    DebugRPCServer+Metrics.swift # GET /metrics handler (line-cap split from DebugRPCServer.route)
    HTTPRequest.swift      # HTTP/1.1 request parsing for DebugRPCServer (line-cap split)
    HTTPResponse.swift     # HTTP/1.1 response serialization for DebugRPCServer (line-cap split)
    RPCStateSnapshot.swift # JSON-serializable RPC state snapshot (#if !APPSTORE)
    RPCResourceMetrics.swift # Cumulative CPU/RAM/instructions self-report via proc_pid_rusage (#if !APPSTORE, served at GET /metrics)
    RPCServerController.swift  # @Observable controller owning DebugRPCServer lifecycle (#if !APPSTORE, wired by AppState)
    Assets.xcassets        # App icon assets
    Info.plist             # Bundle metadata
  Entitlements/
    Homebrew.entitlements  # Mic only (Homebrew/direct distribution)
    AppStore.entitlements  # Sandbox + mic + network + file picker (App Store)
  Tests/                   # Swift tests (XCTest + ViewInspector)
    Fixtures/              # Test audio files (two_speakers_de.wav, etc.)
tools/audiotap/            # AudioTapLib — CATapDescription-based app audio capture (SPM library)
  Package.swift            # SPM manifest (macOS 14+, library target)
  Sources/
    AppAudioCapture.swift  # CATapDescription + IOProc → FileHandle
    AppAudioCapture+PIDTranslation.swift  # Translates PIDs to CoreAudio AudioObjectIDs (multi-process tap for Electron apps)
    AppAudioCapture+DebugLogging.swift # Per-buffer dBFS/RMS logging helpers extracted from AppAudioCapture (line-cap split)
    AppAudioCapture+LiveSink.swift # Live-buffer forwarding from CATap IOProc into LiveAudioBuffer sinks (line-cap split)
    MicCaptureHandler.swift # AVAudioEngine → WAV
    AudioCaptureSession.swift # Orchestrator (start/stop, computes micDelay)
    AudioCaptureResult.swift  # Result struct
    LiveAudioBuffer.swift  # Real-time audio sample snapshot yielded from capture callbacks (CATap IOProc + AVAudioEngine input tap)
    CurrentLevel.swift     # Pure function: dBFS level read with staleness decay (stale tap → silence)
    LevelPublisher.swift   # Cross-thread dBFS slot (audio callback writes, UI thread reads)
    DebugRMSReporter.swift # Throttled RMS accumulator/reporter for audio debug logging
    Helpers.swift          # machTicksToSeconds, getDefaultOutputDeviceUID, writeAllToFileHandle
    MicRestartPolicy.swift # Pure decision logic for mic engine restart on device change
    OutputDeviceChangeCoordinator.swift # State machine for output device change + tap restart flow
    ProcessTreeEnumerator.swift  # Enumerates all PIDs under an .app bundle (Electron/Teams child-process support)
    SampleRateQuery.swift  # Pure functions for sample rate detection and cross-validation
    AVAudioNode+SafeInstallTap.swift  # Safe installTap wrapper catching NSException via CExceptionCatcher (issue #379)
    AppAudioCapture+Resampling.swift  # Capture-time resampling for CATap buffers (line-cap split)
    AppAudioCapture+TapError.swift    # Tap-creation error mapping for AppAudioCapture (line-cap split)
    CExceptionCatcher/               # Obj-C module catching AVFoundation NSException from installTapOnBus
    DebugTapFault.swift              # Fault-injection configuration for mic device-change E2E (issue #379)
    MicCaptureHandler+Timeline.swift  # Timeline tracking for MicCaptureHandler across device-change restarts
    MicRestartRetryPolicy.swift      # Retry/backoff policy for failed mic engine restarts
    StreamingMonoResampler.swift     # Streaming mono resampler for live 16 kHz audio path
    TapFormatResolver.swift          # Derives mic tap format from hardware format (prevents installTap channel mismatch)
    TimelineAnchor.swift             # Wall-clock timeline anchor across device-change restarts (aligns track to real time)
  Tests/
    AppAudioCaptureDebugLoggingTests.swift
    AppAudioCaptureLiveSinkTests.swift
    AppAudioCapturePIDTranslationTests.swift
    AppAudioCaptureResamplingTests.swift
    AppAudioCaptureStatusTests.swift
    AudioCaptureResultTests.swift
    CExceptionCatcherTests.swift
    CurrentLevelTests.swift
    DebugRMSReporterTests.swift
    HelpersTests.swift
    LevelPublisherTests.swift
    LiveAudioBufferTests.swift
    MicCaptureErrorTests.swift
    MicCaptureHandlerTimelineTests.swift
    MicRestartPolicyTests.swift
    MicRestartRetryPolicyTests.swift
    OutputDeviceChangeCoordinatorTests.swift
    ProcessTreeEnumeratorTests.swift
    SampleRateQueryTests.swift
    StreamingMonoResamplerTests.swift
    TapFormatResolverTests.swift
    TimelineAnchorTests.swift
tools/meeting-simulator/   # Meeting simulator tool for testing
  Package.swift
  Sources/main.swift
tools/mt-cli/              # Thin Swift client for DebugRPCServer (state, screenshot, open-settings, …)
  Package.swift
  Sources/
    MTCLI.swift            # ArgumentParser entrypoint
    RPCClient.swift        # HTTP client; reads token from AppPaths-equivalent path
  Tests/RPCClientTests.swift
  skill.md                 # Claude skill: when to use mt-cli, with examples
scripts/
  build_release.sh         # Build self-contained .app bundle + DMG (--appstore for App Store variant)
  notarize_status.sh       # Check Apple notarization status
  run_app.sh               # Build + sign + launch menu bar app bundle (--build-only skips `open -W`)
  e2e-app.sh               # Live-recording E2E driver: build + deploy dev.app, trigger meeting-simulator, assert on RPC /state.lastJob
  e2e-channel-health.sh    # E2E test for per-channel signal indicator (forces mic-silent state + asserts red-tint via RPC screenshot)
  e2e-silent-recording.sh  # E2E test for silent-recording detector (both channels at noise floor → in-app warning)
  e2e-live-captions.sh     # E2E driver asserting on in-flight liveCaptions.recentFinals RPC state (complements e2e-app.sh)
  e2e-cpu-load.sh          # E2E resource measurement: idle + recording-without-captions + recording-with-live-captions CPU/RAM of the deployed app via RPC /metrics deltas (logs trends, gates only a generous idle-CPU catastrophe bound)
  setup-self-hosted-runner.sh  # One-time: self-signed code-signing cert + manual TCC grants keyed on cert SHA-1 (needed before e2e-app.sh works)
  generate_test_audio.sh   # Generate 2-speaker test WAV fixture (requires sox)
  generate_test_audio_3speakers.sh  # Generate 3-speaker test WAV fixture (requires sox)
  generate_test_audio_with_silence.sh # Generate 2-speaker fixture with engineered silence block for VAD E2E tests
  generate_quality_fixtures.sh # Generate WER/DER quality ground-truth fixtures (WAV + truth JSON, requires sox)
  build_perf_report.sh     # Build performance analysis: CI run history → job duration trends + slowdown alerts
  configure-tag-ruleset.sh  # Configure/update GitHub Tag Ruleset for stable-tag protection (idempotent)
  lint.sh                   # Lint & format (--fix to auto-correct; runs SwiftFormat + SwiftLint)
  test_rpc.sh               # Live smoketest for DebugRPCServer (build + launch + drive via mt-cli + assert)
  pre-push.sh               # Pre-push parity check: swift build -c release (catches Sendable diagnostics that debug-mode builds tolerate)
  export-lcov.sh            # Export LCOV coverage for an SPM package's xctest bundle
  keychain-prepend.sh       # Idempotent keychain search-list prepend (used by setup-self-hosted-runner.sh)
  generate_menu_bar_gifs.swift      # Generate menu bar animation GIFs
  assert-red-pixels.swift   # Visual regression assertion for menu-bar red-tint indicator (counts red pixels in PNG)
  bless_quality_baseline.sh  # Project quality results into slim baseline JSON for CI regression gate
  generate_social_preview.py  # Generate GitHub social preview card (docs/social-preview.png)
  generate_test_audio_en.sh  # Generate English 2-speaker test WAV fixture (two_speakers_en.wav, requires say + sox)
  lib/e2e-helpers.sh        # Shared helpers sourced by e2e-app.sh, e2e-channel-health.sh, e2e-silent-recording.sh
  tests/
    test_build_release_signing.sh  # Regression test for build_release.sh codesign-identity detection
Casks/meeting-transcriber.rb # Homebrew Cask formula (stable)
Casks/meeting-transcriber@beta.rb # Homebrew Cask formula (pre-release)
.github/workflows/
  ci.yml                   # CI: lint + analyze + Swift tests (3 parallel jobs)
  release.yml              # CI: build DMG + GitHub Release on tag push
  pr-labels.yml            # Automatic PR labeling
  e2e.yml                  # E2E — fixture-based xctest on self-hosted Mac (dispatch + main push)
  e2e-app.yml              # E2E — deployed dev .app + live recording + RPC-driven assertion (dispatch + push to main + nightly)
  e2e-cpu-load.yml         # E2E — idle + in-meeting CPU/RAM measurement of the deployed app (dispatch + nightly trend cron, RESULT artifact)
  appstore.yml             # App Store variant smoke test: build + launch-check (main push + nightly + dispatch)
  build-perf-tracking.yml  # Weekly build performance trend analysis (flags regressions vs 28-day baseline)
  quality-and-safety.yml   # TSan/ASan matrix + WER/DER quality regression (main + nightly + dispatch)
  dependabot-auto-merge.yml # Auto-merge Dependabot patch/minor and github-actions bumps
  e2e-crash-recovery.yml    # E2E — crash recovery: SIGKILL mid-recording + verify pipeline recovers via WAV header repair
  e2e-mic-device-change.yml # E2E — mic device-change NSException survival (issue #379, fault-injection build)
  pages.yml                 # Deploy landing page to GitHub Pages (site/ → GitHub Pages, main push + dispatch)
docs/
  architecture-macos.md        # High-level architecture quick-reference
  menu-bar-*.gif               # Menu bar icon animation GIFs (idle, recording, transcribing, diarizing, protocol, permission, record-only, channel-silent-app, channel-silent-mic)
  plans/
    appstate-tests.md          # AppState test expansion plan
    2026-03-10-repo-review.md  # Repository review findings
    2026-03-21-workflow-integration-tests.md  # Workflow integration test plan
protocols/                 # Output directory (gitignored)
speakers.json              # Saved voice profiles (gitignored, created at runtime)
.env                       # Environment variables (gitignored)
```

## Pipeline

```
Dual-source: AudioTapLib (CATapDescription + AVAudioEngine) → separate 16kHz audio → [WhisperKit | Parakeet | Qwen3] per track → FluidAudio diarization per track (CoreML/ANE) → merge speakers → Claude CLI / OpenAI-compatible API → Markdown protocol
Single-source: Audio/Video → 16kHz mono (AVAudioFile → AVAsset → ffmpeg fallback) → [WhisperKit | Parakeet | Qwen3] → FluidAudio diarization → Claude CLI / OpenAI-compatible API → Markdown protocol
```

## Setup

```bash
# Run menu bar app (builds automatically, including AudioTapLib):
./scripts/run_app.sh
```

## Key Commands

```bash
# Run menu bar app
./scripts/run_app.sh

# Swift tests (parallel — ~1.4× faster than sequential)
cd app/MeetingTranscriber && swift test --parallel

# Swift tests under sanitizers (slow — TSan ~7.5 min, ASan ~4.5 min on M-series)
# CI runs these nightly via cron + on push to main; locally use ad-hoc
# before pushing concurrency-heavy or C-bridging changes.
cd app/MeetingTranscriber && swift test --parallel --sanitize=thread --skip MenuBarIconSnapshotTests
cd app/MeetingTranscriber && swift test --parallel --sanitize=address --skip MenuBarIconSnapshotTests

# Trigger sanitizer matrix on a specific PR/branch via CI
gh workflow run quality-and-safety.yml -f run-sanitizer=true -f run-quality=false

# Lint & format check (dry-run, no changes)
./scripts/lint.sh

# Lint & format auto-fix (SwiftFormat + SwiftLint --fix)
./scripts/lint.sh --fix

# Pre-push parity check (release build — catches Sendable diagnostics
# that debug-mode tolerates; flags App Store variant when --with-appstore)
./scripts/pre-push.sh

# Build self-contained .app + DMG for distribution (Homebrew)
./scripts/build_release.sh

# Run app with debug RPC server enabled (dev-only; binds 127.0.0.1:9876)
MEETINGTRANSCRIBER_DEBUG_RPC=1 ./scripts/run_app.sh

# Build mt-cli (talks to the running RPC server)
cd tools/mt-cli && swift build && .build/debug/mt-cli state

# Live smoketest of the RPC server (kills + builds + launches + asserts)
./scripts/test_rpc.sh

# Build App Store variant (sandbox, no Claude CLI)
./scripts/build_release.sh --appstore --no-notarize
```

## Distribution

The app can be distributed as a self-contained `.app` via Homebrew Cask:

```bash
# Build DMG locally
./scripts/build_release.sh

# Install stable via Homebrew
brew tap pasrom/meeting-transcriber
brew install --cask meeting-transcriber

# Install pre-release (RC) via Homebrew
brew install --cask meeting-transcriber@beta
```

> Note: The stable and beta casks conflict — uninstall one before installing the other.

**Release workflow:** Push a `v*` tag to trigger `.github/workflows/release.yml` which
builds the DMG on a macOS runner and creates a GitHub Release. Stable tags update the
`meeting-transcriber` cask, pre-release tags (containing `-`) update `meeting-transcriber@beta`.

**Stable tag gate:** A GitHub Tag Ruleset (`Stable tag protection`) rejects any
`git push` of a tag matching `v*` *without* a `-` suffix unless the tagged SHA
has green status checks for every context listed in
`.github/tag-ruleset.json` (`required_status_checks`). Apply or update the
ruleset via `./scripts/configure-tag-ruleset.sh` (idempotent, needs repo-admin
`gh` auth). RC tags (`v*-rc*`) stay unrestricted. `e2e.yml` and `e2e-app.yml`
both fire on every main push (no paths-filter) so every SHA a stable tag might
point at already has the required check-runs — no manual `gh workflow run`
ceremony before tagging.

## Git Workflow

Use the `/git-workflow` skill. Commit proactively after every logical unit of work — don't wait for user permission.

- **Conventional Commits:** `<type>(<scope>): <description>` — types: feat, fix, docs, refactor, test, perf, chore, build
- **Scopes:** app, test, build, ci, docs
- **Atomic commits:** one logical change per commit. If you need "and" in the message, split it.
- **Stage explicitly:** `git add <file1> <file2>` — never `git add -A` or `git add .`
- **Verify first:** run tests before committing
- **Commit body:** document the WHY for non-trivial changes (architecture decisions, rejected alternatives)
- **Never push to main directly.** Always create a branch, open a PR, and merge via `gh pr merge --rebase --delete-branch`. Only exception: version bumps in `VERSION` file.
- **Rebase merge only.** Squash and merge commits are disabled by repo policy.

## Conventions

- All code and UI text in English
- Protocol output language configurable via `AppSettings.protocolLanguage` (default: German)
- **Plan files:**
  - `docs/plans/` (committed) — RFCs and reference docs for future features that should be visible to anyone reading the repo
  - `docs/plans/.local/` (gitignored) — personal scratch; optional subfolders `open/`, `research/`, `done/`, `future/`, `deferred/`
  - Default to `.local/` for ad-hoc notes, diagnostic dumps, and active finding-trackers; promote to committed `docs/plans/` only when the plan is shared reference material
  - **Never reference `.local/` content in shared artifacts** (PR descriptions, commit messages, code comments, in-app UI, GitHub issues): no file paths under `.local/`, no internal task identifiers like P4/P6/B22/H1/L6, no internal PR-internal nicknames. Reviewers don't see those. Inline the relevant content instead, or describe in plain language. The same applies to chat replies framed as PR/commit-ready text.

## Architecture Notes

**Transcription engines:**
- `TranscribingEngine` protocol abstracts ASR backends. Three implementations: `WhisperKitEngine` (99+ languages, ~1 GB model), `ParakeetEngine` (25 EU languages, ~50 MB model, ~10× faster), and `Qwen3AsrEngine` (30 languages, ~1.75 GB model, macOS 15+).
- `AppSettings.transcriptionEngine` enum (`.whisperKit` / `.parakeet` / `.qwen3`) selects the engine. Settings UI shows engine picker; engine-specific options hidden when not selected. `availableCases` filters by macOS version.
- Parakeet auto-detects language (no parameter) and supports custom vocabulary via CTC boosting (`ParakeetEngine.customVocabularyPath`). WhisperKit and Qwen3 support explicit language selection.
- `Qwen3AsrEngine` requires macOS 15+ (`@available`). Returns plain text (no timestamps) — emits single `TimestampedSegment`. Chunks audio into <=30s windows (`Qwen3AsrConfig.maxAudioSeconds`). Type-erased in `EngineController` via `_qwen3Engine: AnyObject?` for macOS <15 compatibility.
- `EngineController` (`@MainActor`) owns the three engine instances + the active-engine selection (`activeTranscriptionEngine`, used by `PipelineQueue`) + the settings → engine language/vocabulary sync (up-front + reactive) + launch model preload. `AppState` exposes it as `engines`.

**Concurrency:**
- `WatchLoop` is `@MainActor`. Tests for this class must also be `@MainActor`.
- All three engine `loadModel()` methods deduplicate concurrent calls via `loadingTask` — second caller awaits the first's task. Safe to call from multiple places.
- `ClaudeCLIProtocolGenerator` uses async process I/O: the process `terminationHandler` yields into an `AsyncStream<Void>` that the caller awaits, instead of blocking on `process.waitUntilExit()`. The stream is installed before `process.run()` and buffers the yield, so an early exit is never missed. stdin/stdout are written/read in detached `Task`s.

**View architecture:**
- `SettingsView` receives its dependencies as stored properties (not `@State`): the three engine instances, `updateChecker`, `recognitionStatsLog`, an `enrollmentDiarizerFactory`, the `namingDialogActive`/`pipelineBusy` state flags, and an `onSpeakerMutate` callback. `qwen3Engine` is `(any TranscribingEngine)?` — nil on macOS <15.

**Audio loading:**
- `AudioMixer.loadAudioAsFloat32()` uses a 3-tier fallback: `AVAudioFile` → `AVAsset` → `FFmpegHelper` (ffmpeg CLI).
- `loadAudioFromAVAsset()` extracts audio tracks via `AVAssetReader`, outputs 16kHz Float32 PCM.
- `FFmpegHelper` detects ffmpeg binary (env var → `/opt/homebrew/bin` → `/usr/local/bin` → `~/.local/bin` → `/usr/bin`), cached via static let. Converts to 16kHz mono WAV via temp file.
- File picker supports WAV, MP3, M4A, MP4, MOV, and other AVAsset-compatible formats. MKV, WebM, OGG shown only when ffmpeg is detected.
- ffmpeg is optional — install via `brew install ffmpeg`. Status shown in Settings → About.

**Recording:**
- `DualSourceRecorder` uses `AudioTapLib.AudioCaptureSession` directly (no subprocess). App imports the library via SPM local package dependency.
- `DualSourceRecorder` captures `recordingStartTime` in `start()`, not in `stop()`.
- Grace period minimum is 1 second (enforced in `AppSettings.endGrace` setter).

**Detection:**
- `MeetingDetecting` protocol abstracts detection strategies. Two implementations: `MeetingDetector` (window title matching via `CGWindowListCopyWindowInfo`) and `PowerAssertionDetector` (IOKit power assertions — sandbox-safe, no Screen Recording permission needed).
- `MeetingDetector` counts each pattern once per poll — prevents over-counting when multiple windows match the same app.

**Diarization:**
- `FluidDiarizer` uses FluidAudio (CoreML/ANE) for on-device speaker diarization — no HuggingFace token needed. Two modes: `.offline` (default) and `.sortformer` (overlap-aware, via `SortformerDiarizer`). Selected via `AppSettings.diarizerMode`.
- **Dual-track diarization:** App and mic tracks are diarized separately. Speaker IDs are prefixed (`R_` for remote/app, `M_` for mic/local), merged, and assigned via `assignSpeakersDualTrack`. Single-source recordings fall back to diarizing the mix with `assignSpeakers`.
- **Sortformer post-hoc embeddings:** `FluidDiarizer+SortformerEmbeddings.swift` extracts per-speaker WeSpeaker embeddings after Sortformer diarization (DiariZen-style hybrid), using overlap-excluded masks so mixed-speaker frames don't contaminate centroids. Enables `SpeakerMatcher` recognition when using the Sortformer mode.
- `SpeakerMatcher` stores speakers in `speakers.json` with a running-mean **centroid** (primary anchor) plus a recent-samples FIFO (max 3, fallback when centroid match is borderline). Quality filter: embeddings from segments shorter than `minSpeakingTimeForCentroid` (3 s) are kept as fallback samples but excluded from the centroid. Threshold 0.40, confidence margin 0.10. Legacy entries without a persisted centroid compute `meanEmbedding(embeddings)` lazily until the next confirmation seeds a real centroid.
- **Live speaker matching:** `LiveSpeakerMatcher` (actor) matches finalized live-caption utterances against `speakers.json` in real time using the same WeSpeaker CoreML model as the batch pipeline — voices enrolled post-meeting are recognised in subsequent live sessions without re-enrollment. Cold-start optimisation: caches the WeSpeaker mask frame count in `UserDefaults` so only the embedding model is loaded on subsequent launches.
- **Experimental diarization tuning:** `AppSettings` exposes five `OfflineDiarizerConfig` knobs (`clusterThreshold`, `warmStartFa`, `warmStartFb`, `minSegmentDurationSeconds`, `excludeOverlap`) editable via Settings → Speakers → Experimental Diarization Tuning. All default to FluidAudio community values; a reset button restores defaults.
- `DiarizationProvider` protocol enables mock injection in tests.

**VAD preprocessing:**
- `FluidVAD` wraps FluidAudio Silero v6 for voice activity detection. When enabled (`AppSettings.vadEnabled`), silence is trimmed before transcription and timestamps are remapped back to the original timeline via `VadSegmentMap`.
- `PipelineQueue` holds a cached `FluidVAD` instance (reused across jobs). Pass `vadConfig: nil` to disable.

**Protocol generation:**
- `ProtocolGenerating` protocol with two implementations: `ClaudeCLIProtocolGenerator` and `OpenAIProtocolGenerator`.
- `AppSettings.protocolProvider` enum (`.claudeCLI` / `.openAICompatible` / `.none`) selects the provider. `.none` skips LLM generation and saves the transcript only.
- `AppSettings.protocolLanguage` string (default `"German"`) is substituted into the prompt as `{LANGUAGE}`.
- `ProtocolGenerator.loadPrompt()` loads custom prompt from `AppPaths.customPromptFile` (`~/Library/Application Support/MeetingTranscriber/protocol_prompt.md`), falls back to built-in default.
- `OpenAIProtocolGenerator` supports any OpenAI-compatible HTTP API (Ollama, LM Studio, llama.cpp, etc.).

**UI:**
- `MenuBarIcon` renders animated waveform reflecting pipeline state (idle, recording, transcribing, diarizing, protocol).
- `AppPickerView` enables manual recording of any app via app picker.
- `UpdateChecker` checks GitHub releases for newer versions, shows badge on menu bar icon.

**Permission health check:**
- `PermissionHealthCheck` verifies each TCC permission by combining the system verdict with a live probe. Each resolves to `PermissionStatus` (`.healthy | .denied | .broken | .notDetermined`). `.broken` means TCC says allowed but the probe disagrees — fix is to toggle the permission off and on in System Settings.
- `WatchLoop` runs the check on startup; `AppState` re-runs on app activation.
- When unhealthy: `MenuBarIcon` composites a red "!" badge over the current icon (non-template, stays red in dark mode). `BadgeKind.compute()` returns `.error` when idle with a problem. A deduped notification is posted via `NotificationManager`.

**Debug RPC server (dev-only):**
- `DebugRPCServer` is an embedded HTTP server bound to `127.0.0.1:9876` that exposes app state, screenshots, and scene actions for shell-driven inspection. Whole file is `#if !APPSTORE`. Two enable paths: persistent `Settings → Advanced → Debug RPC Server` toggle (off by default), or per-session `MEETINGTRANSCRIBER_DEBUG_RPC=1` env var (force-starts at launch). `AppState.applyDebugRPCSetting()` reconciles the running server with both signals at startup and on toggle changes.
- Endpoints: `GET /state` (pipeline + speaker DB + engine state JSON; `engines.*.modelState` lets driver scripts wait for model preload), `GET /healthz`, `GET /metrics` (cumulative CPU/RAM/instructions self-report via `proc_pid_rusage` — diff two snapshots for window averages; process-only, child processes excluded; consumed by `scripts/e2e-cpu-load.sh`), `GET /screenshot` (PNG of the largest visible window), `POST /action/openSettings`, `POST /action/closeSettings`.
- Two-layer auth: 32-byte hex bearer token at `~/Library/Application Support/MeetingTranscriber/.rpc-token` (chmod 0600) + reject on any non-empty browser `Origin` header.
- Action endpoints post `Notification.Name.showSettings` / `.closeSettings` that the `@main` scene observes and routes to `bringWindowToFront(id: "settings")` / `closeWindow(id: "settings")` — same path the menu bar uses.
- `tools/mt-cli` is the matching CLI client; `scripts/test_rpc.sh` is a live end-to-end smoketest. In-process integration tests live in `Tests/DebugRPCServerIntegrationTests.swift` (real sockets via OS-assigned port exposed through `DebugRPCServer.boundPort`).

**Record-only mode:**
- When `AppSettings.recordOnly` is true, `WatchLoop.enqueueRecording()` moves the dual-source WAVs into `<settings.effectiveOutputDir>/recordings/` and writes a `<basename>_meta.json` `RecordingSidecar` next to them, skipping the entire post-processing pipeline (VAD, transcription, diarization, protocol generation). Both call sites — auto-detected meetings (`handleMeeting`) and manual recordings (`stopManualRecording`) — flow through the same branch. The destination is wrapped in `startAccessingSecurityScopedResource()` to honour user-picked Output Folder bookmarks (relevant for the App Store sandboxed build).
- Sidecar JSON contains: `version` (currently `RecordingSidecar.currentVersion = 1`), `title`, `appName`, `startedAt`/`stoppedAt` (ISO 8601, reconstructed from `recordingStart` uptime), `participants`, `micDelaySeconds`, `files` (basenames only). Optional `app` / `mic` filenames are omitted when nil. Suffix constants live as static lets: the audio-file suffixes on `RecordingFileSuffix` (`mix = "_mix.wav"`, `app`, `mic`, and the raw-temp `appRaw`/`legacyAppRaw`), and the sidecar suffix on `RecordingSidecar.filenameSuffix = "_meta.json"`.
- Intended for fleet topologies where macOS clients capture and a separate machine (e.g. Linux GPU host) processes the audio via Syncthing or similar.
- Menu bar: the small red dot is rendered as a **persistent overlay** (`MenuBarIcon.image(..., recordOnlyOverlay:)`) on top of *whatever* primary badge `BadgeKind.compute(...)` would otherwise show — idle, recording, transcribing, etc. — so the mode is always visible. Permission overlay (red exclamation) takes precedence when both apply, since a permission problem actually breaks recording. Settings tabs dim Transcription / Protocol / VAD / Diarization sections via `View.recordOnlyDisabled(_:)` and show a banner in the General tab pointing at the active output dir.
- Sidecar write failures notify the user via `NotificationManager` (injected as `any AppNotifying` on `WatchLoop`) since record-only does not transition state to `.error`.

## Critical Notes

- AudioTapLib (CATapDescription) requires macOS 14.2+ — compiled as SPM library, no separate binary needed
- Screen Recording permission required for **meeting detection** (window titles via `CGWindowListCopyWindowInfo`)
- Audio capture (AudioTapLib) does NOT require Screen Recording — uses CATapDescription (purple dot indicator)
- FluidAudio models are downloaded automatically on first run (~50 MB)

## E2E Architecture

Two complementary E2E approaches, run by different workflows. Pick by what
you're validating:

**Fixture-based xctest E2E (`e2e.yml`)**
- Engine + pipeline tests in `app/MeetingTranscriber/Tests/*E2ETests.swift`
  (Parakeet, WhisperKit, Qwen3, WatchLoop) feed pre-recorded `two_speakers_de.wav`
  into the components and assert on transcripts.
- Triggered on `workflow_dispatch` and every push to `main`.
- No live recording — `DualSourceRecorder` is bypassed; tests substitute
  fixture WAVs at the same point the recorder would emit them.
- Strengths: fast, deterministic, isolates engine logic; runs in xctest's
  sandboxed harness without TCC concerns.
- Limitations: can't catch regressions in the recording stack, the audio
  routing path, TCC interactions, or detector → recorder handoff.

**Live-recording E2E (`e2e-app.yml`, `scripts/e2e-app.sh`)**
- Builds the dev `.app`, deploys to `~/Applications/MeetingTranscriber-Dev.app`
  (stable path → TCC permissions persist), launches it, triggers a meeting
  via `meeting-simulator`, polls `DebugRPCServer`'s `/state` for
  `lastJob.state == .done`, asserts on the resulting transcript file.
- Triggered on `workflow_dispatch`, every `push` to main (no paths-filter
  — so the stable-tag ruleset always has a push-event check-run on the
  SHA), and a nightly cron at 04:30 UTC.
- Exercises the production code path end-to-end including TCC, audio
  routing, CATapDescription tap, and the dual-track recorder/diarizer
  handoff.
- Limitations: needs one-time runner setup (see below); can't run on
  GitHub-hosted runners — only on a self-hosted Mac with an interactive
  GUI session and a stable code-signing identity.

**Why the live-recording variant exists** (history that's easy to lose):
- An earlier attempt at xctest-framed live recording (PR #100,
  `E2EFullPipelineTests`) crashed reproducibly with
  `freed pointer was not the last allocation` on the self-hosted Mac mini.
  Root cause: ad-hoc-signed xctest binaries get a fresh cdhash on every
  build, never inherit stable TCC permissions, and AVAudioEngine on a
  no-input host hits a libmalloc abort.
- The production `.app` doesn't have any of those problems because it has
  a stable bundle ID + (with `setup-self-hosted-runner.sh`) a stable
  signing identity whose cert leaf SHA-1 TCC keys its permission grants on,
  so the grants survive rebuilds.

**One-time self-hosted runner setup**:
1. `brew install blackhole-2ch` then reboot (or `sudo killall coreaudiod`),
   set BlackHole 2ch as the default Input in System Settings → Sound.
   Mac mini hosts have no built-in mic; without a virtual input device
   the dual-source recorder hits the libmalloc abort path.
2. Configure auto-login for the runner user so loginwindow brings up an
   Aqua session at boot. CATapDescription captures silence in non-GUI
   contexts even when API calls return `noErr`.
3. Run `scripts/setup-self-hosted-runner.sh` once. It creates a self-signed
   code-signing cert in a dedicated dev keychain, builds the dev `.app`, signs
   it with that cert, and deploys to `~/Applications/`. It does NOT install a
   configuration profile: macOS ignores a non-MDM-delivered PPPC payload, and
   the MDM/`add-trusted-cert -d` path needs an actual MDM server (unavailable
   here). TCC permissions are instead granted manually, once, and macOS keys
   the grant on the cert leaf SHA-1.
4. In the GUI session, launch the deployed `.app`
   (`open ~/Applications/MeetingTranscriber-Dev.app`). Click "Allow" on the
   Microphone prompt, and toggle the dev `.app` on under System Settings →
   Privacy & Security → Screen & System Audio Recording (used for window-title
   meeting detection — the e2e also has a sandbox-safe power-assertion detector,
   so this one is belt-and-suspenders).
5. Verify Microphone + Screen & System Audio Recording show the dev `.app`
   with the toggle on.

After setup, every CI run rebuilds + re-signs the `.app`; the cdhash differs
per build but the cert leaf SHA-1 doesn't, so TCC keeps the manual grant across
rebuilds. The grant keys on the cert of whatever bundle you Allowed — CI
re-signs with the Developer ID cert each run, so make the grant against a
Developer-ID-signed bundle (the state CI leaves at `~/Applications/`).

NOTE: the dev `.app` is **unnotarized** Developer ID (`spctl` reports
"rejected"), and macOS occasionally revokes TCC grants for such apps — observed
2026-06-05: e2e-app went green→red overnight with no reboot, no OS/XProtect
update, and no rebuild, because the Microphone grant was silently dropped and
the headless run then blocked on the consent prompt (first lane fails with
`no new pipeline job within 240s, active=0`). Remedy: re-click "Allow" in the
GUI session. Notarizing the dev build or a real MDM-delivered PPPC profile
would make the grant fully durable; neither is set up.

## Diagnostics

`AppSettings.audioDebugLogging` (Settings → Diagnostics → "Verbose Audio Logging") enables forensic logging in the audio-capture path:

- `[debug] Tap target: pid=… exe=… bundle=… audioObjectID=…` at start
- `[debug] Default output device: name=… uid=… transport=… rate=…` at start and on device change
- `[debug] Tap format: rate=… Hz, tapID=…` after tap is configured
- `[debug] Output device change → name=… uid=…` when system output device changes mid-capture
- `[debug] App audio RMS (5s): … dBFS, samples=…, totalBytes=…` every 5 s during capture — live signal whether the tap is delivering real audio or zero/noise
- `[debug] App audio capture stopping: totalBytes=…` at stop
- `[debug] Mic input device: name=… uid=… hwRate=… hwChannels=…` at mic capture start
- `[debug] Mic RMS (5s): … dBFS, samples=…` every 5 s during mic capture

View via Console.app, subsystem `com.meetingtranscriber.audiotap`. Off by default; turn on when investigating silent recordings or unusual routing.

## Build Variants

Two build variants controlled by compile-time flag `APPSTORE` (`-Xswiftc -DAPPSTORE`):

| | Homebrew | App Store |
|---|---|---|
| **Claude CLI** | Yes (Process subprocess) | No (sandbox forbids Process) |
| **OpenAI API** | Yes | Yes (only LLM option) |
| **Debug RPC server** | Yes (env-gated) | No (`#if !APPSTORE`) |
| **Entitlements** | Mic only | Sandbox + mic + network + file picker |
| **Build** | `./scripts/build_release.sh` | `./scripts/build_release.sh --appstore` |
| **Tests** | ~1,900 | fewer (CLI + RPC tests excluded via `#if !APPSTORE`) |

- CLI-specific code lives in `ClaudeCLIProtocolGenerator.swift` and `DebugRPCServer.swift` (each entire file `#if !APPSTORE`)
- `ProtocolProvider` enum uses `CaseIterable` — `.claudeCLI` case excluded at compile time, picker adapts automatically
- `ProtocolError` has `#if !APPSTORE` around CLI error cases (enum cases cannot be added via extension)
- FFmpegHelper also uses `Process()` but falls back gracefully to `nil` — no `#if` needed
