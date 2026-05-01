# Meeting Transcriber

## Project Structure

```
VERSION                    # App version (read by build scripts)
app/MeetingTranscriber/    # Swift macOS menu bar app (SPM)
  Package.swift            # SPM manifest (WhisperKit + FluidAudio + AudioTapLib runtime deps; ViewInspector + SnapshotTesting test deps)
  Sources/
    MeetingTranscriberApp.swift  # @main, UI shell (scenes, NSOpenPanel, NSWorkspace)
    AppState.swift         # @Observable @MainActor ViewModel (business state, badge logic, pipeline wiring)
    AudioConstants.swift   # Shared audio pipeline constants (target sample rate)
    MenuBarView.swift      # Menu bar dropdown UI
    MenuBarIcon.swift      # Animated waveform menu bar icon + BadgeKind.compute() pure function
    SettingsView.swift     # Settings window
    SpeakerNamingView.swift # Speaker naming dialog + AccessibleTextField
    AppPickerView.swift    # App picker for manual recording
    AppPaths.swift         # Centralized paths (ipcDir, dataDir, logSubsystem, speakersDB)
    AppSettings.swift      # @Observable settings (UserDefaults + file-based secrets)
    AXHelper.swift         # Shared accessibility API helper
    NotificationManager.swift # macOS notifications
    KeychainHelper.swift   # Keychain CRUD (legacy/test-only, token now file-based)
    TranscriberStatus.swift # Status + MeetingInfo models
    TranscribingEngine.swift # TranscribingEngine protocol + mergeDualSourceSegments default impl
    WhisperKitEngine.swift # WhisperKit transcription engine (CoreML/ANE, 99+ languages)
    ParakeetEngine.swift   # NVIDIA Parakeet TDT v3 engine via FluidAudio (CoreML/ANE, 25 EU languages)
    Qwen3AsrEngine.swift   # Qwen3-ASR 0.6B engine via FluidAudio (CoreML/ANE, 30 languages, macOS 15+)
    FluidDiarizer.swift    # CoreML-based speaker diarization via FluidAudio (on-device, OfflineDiarizer + Sortformer modes)
    FluidVAD.swift         # VAD preprocessing via FluidAudio Silero v6 (silence trimming + timeline remapping)
    SpeakerMatcher.swift   # Speaker embedding DB + cosine similarity matching
    DiarizationProcess.swift  # DiarizationProvider protocol + result types
    PipelineQueue.swift    # Decouples recording from post-processing (transcription → diarization → protocol)
    PipelineJob.swift      # Pipeline job model
    ProtocolGenerator.swift   # Shared protocol utilities: prompts, file I/O, ProtocolError
    ClaudeCLIProtocolGenerator.swift # Claude CLI subprocess protocol generation (#if !APPSTORE)
    OpenAIProtocolGenerator.swift # OpenAI-compatible API protocol generation (Ollama, LM Studio, etc.)
    WatchLoop.swift        # @MainActor watch loop: detect → record → enqueue PipelineJob
    DualSourceRecorder.swift  # App audio (AudioTapLib) + mic recording (captures startTime in start())
    MeetingDetecting.swift # MeetingDetecting protocol + DetectedMeeting model
    MeetingDetector.swift  # Window title matching (counts each pattern once per poll)
    FFmpegHelper.swift     # ffmpeg CLI detection + audio extraction for MKV/WebM/OGG
    AudioMixer.swift       # Multi-format audio loading (WAV/MP3/M4A/MP4 via AVAsset fallback, MKV/WebM/OGG via ffmpeg) + mixing to 16kHz mono
    MicRecorder.swift      # Microphone recording via AVAudioEngine
    PermissionHealthCheck.swift # Permission health check (TCC verdict + live probe → PermissionStatus)
    PermissionRow.swift    # Permission status row UI component
    Permissions.swift      # Permission checks (mic, screen recording)
    ParticipantReader.swift # Reads meeting participants via accessibility
    MeetingPatterns.swift  # App-specific window title patterns
    PowerAssertionDetector.swift  # Meeting detection via IOKit power assertions (sandbox-safe)
    UpdateChecker.swift    # GitHub release update checker
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
    MicCaptureHandler.swift # AVAudioEngine → WAV
    AudioCaptureSession.swift # Orchestrator (start/stop, computes micDelay)
    AudioCaptureResult.swift  # Result struct
    DebugRMSReporter.swift # Throttled RMS accumulator/reporter for debug logging paths
    Helpers.swift          # machTicksToSeconds, getDefaultOutputDeviceUID, writeAllToFileHandle
    MicRestartPolicy.swift # Pure decision logic for mic engine restart on device change
    OutputDeviceChangeCoordinator.swift  # Pure state machine for output device change handling
    SampleRateQuery.swift  # Pure functions for sample rate detection and cross-validation
  Tests/
    AudioCaptureResultTests.swift
    HelpersTests.swift
    MicCaptureErrorTests.swift
    MicRestartPolicyTests.swift
    OutputDeviceChangeCoordinatorTests.swift
    SampleRateQueryTests.swift
tools/meeting-simulator/   # Meeting simulator tool for testing
  Package.swift
  Sources/main.swift
tools/whisperkit-cli/      # WhisperKit CLI transcription tool (used by build_whisperkit.sh)
  Package.swift
  Sources/main.swift
scripts/
  build_whisperkit.sh      # Build WhisperKit CLI tool
  build_release.sh         # Build self-contained .app bundle + DMG (--appstore for App Store variant)
  notarize_status.sh       # Check Apple notarization status
  run_app.sh               # Build + sign + launch menu bar app bundle
  generate_test_audio.sh   # Generate 2-speaker test WAV fixture (requires sox)
  generate_test_audio_3speakers.sh  # Generate 3-speaker test WAV fixture (requires sox)
  lint.sh                   # Lint & format (--fix to auto-correct; runs SwiftFormat + SwiftLint)
  generate_menu_bar_gifs.swift      # Generate menu bar animation GIFs
  tests/
    test_build_release_signing.sh  # Regression tests for build script codesign pipeline
Casks/meeting-transcriber.rb # Homebrew Cask formula (stable)
Casks/meeting-transcriber@beta.rb # Homebrew Cask formula (pre-release)
.github/workflows/
  ci.yml                   # CI: lint + analyze + Swift tests (3 parallel jobs)
  release.yml              # CI: build DMG + GitHub Release on tag push
  pr-labels.yml            # Automatic PR labeling
  e2e.yml                  # E2E tests on self-hosted macOS runner (workflow_dispatch + v* tags)
  dependabot-auto-merge.yml  # Auto-merge Dependabot patch/minor and github-actions bumps
docs/
  architecture-macos.md        # High-level architecture quick-reference
  menu-bar-*.gif               # Menu bar icon animation GIFs (idle, recording, transcribing, diarizing, protocol)
  plans/
    swift-architecture.md      # Detailed Swift pipeline architecture
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

# Swift tests
cd app/MeetingTranscriber && swift test

# Lint & format check (dry-run, no changes)
./scripts/lint.sh

# Lint & format auto-fix (SwiftFormat + SwiftLint --fix)
./scripts/lint.sh --fix

# Build self-contained .app + DMG for distribution (Homebrew)
./scripts/build_release.sh

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

## Architecture Notes

**Transcription engines:**
- `TranscribingEngine` protocol abstracts ASR backends. Three implementations: `WhisperKitEngine` (99+ languages, ~1 GB model), `ParakeetEngine` (25 EU languages, ~50 MB model, ~10× faster), and `Qwen3AsrEngine` (30 languages, ~1.75 GB model, macOS 15+).
- `AppSettings.transcriptionEngine` enum (`.whisperKit` / `.parakeet` / `.qwen3`) selects the engine. Settings UI shows engine picker; engine-specific options hidden when not selected. `availableCases` filters by macOS version.
- Parakeet auto-detects language (no parameter) and supports custom vocabulary via CTC boosting (`ParakeetEngine.customVocabularyPath`). WhisperKit and Qwen3 support explicit language selection.
- `Qwen3AsrEngine` requires macOS 15+ (`@available`). Returns plain text (no timestamps) — emits single `TimestampedSegment`. Chunks audio into <=30s windows (`Qwen3AsrConfig.maxAudioSeconds`). Type-erased in AppState via `_qwen3Engine: AnyObject?` for macOS <15 compatibility.
- `AppState.activeTranscriptionEngine` returns the selected engine, used by `PipelineQueue`.

**Concurrency:**
- `WatchLoop` is `@MainActor`. Tests for this class must also be `@MainActor`.
- All three engine `loadModel()` methods deduplicate concurrent calls via `loadingTask` — second caller awaits the first's task. Safe to call from multiple places.
- `ProtocolGenerator` uses async process I/O: `terminationHandler` + `withCheckedContinuation` instead of `process.waitUntilExit()`. stdout/stderr are read in detached `Task`s.

**View architecture:**
- `SettingsView` receives engine instances as stored properties (not `@State`). Constructor: `SettingsView(settings:whisperKitEngine:parakeetEngine:qwen3Engine:updateChecker:)`. `qwen3Engine` is `(any TranscribingEngine)?` — nil on macOS <15.

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
- `FluidDiarizer` uses FluidAudio (CoreML/ANE) for on-device speaker diarization — no HuggingFace token needed. Two modes: `.offlineDiarizer` (default) and `.sortformer` (overlap-aware, via `SortformerDiarizer`). Selected via `AppSettings.diarizerMode`.
- **Dual-track diarization:** App and mic tracks are diarized separately. Speaker IDs are prefixed (`R_` for remote/app, `M_` for mic/local), merged, and assigned via `assignSpeakersDualTrack`. Single-source recordings fall back to diarizing the mix with `assignSpeakers`.
- `SpeakerMatcher` stores speakers in `speakers.json` with a running-mean **centroid** (primary anchor) plus a recent-samples FIFO (max 3, fallback when centroid match is borderline). Quality filter: embeddings from segments shorter than `minSpeakingTimeForCentroid` (3 s) are kept as fallback samples but excluded from the centroid. Threshold 0.40, confidence margin 0.10. Legacy entries without a persisted centroid compute `meanEmbedding(embeddings)` lazily until the next confirmation seeds a real centroid.
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

## Critical Notes

- AudioTapLib (CATapDescription) requires macOS 14.2+ — compiled as SPM library, no separate binary needed
- Screen Recording permission required for **meeting detection** (window titles via `CGWindowListCopyWindowInfo`)
- Audio capture (AudioTapLib) does NOT require Screen Recording — uses CATapDescription (purple dot indicator)
- FluidAudio models are downloaded automatically on first run (~50 MB)

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
| **Entitlements** | Mic only | Sandbox + mic + network + file picker |
| **Build** | `./scripts/build_release.sh` | `./scripts/build_release.sh --appstore` |
| **Tests** | ~996 | fewer (CLI tests excluded via `#if !APPSTORE`) |

- CLI-specific code lives in `ClaudeCLIProtocolGenerator.swift` (entire file `#if !APPSTORE`)
- `ProtocolProvider` enum uses `CaseIterable` — `.claudeCLI` case excluded at compile time, picker adapts automatically
- `ProtocolError` has `#if !APPSTORE` around CLI error cases (enum cases cannot be added via extension)
- FFmpegHelper also uses `Process()` but falls back gracefully to `nil` — no `#if` needed
