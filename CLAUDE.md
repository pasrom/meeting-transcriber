# Meeting Transcriber

## Project Structure

```
VERSION                    # App version (read by build scripts)
app/MeetingTranscriber/    # Swift macOS menu bar app (SPM)
  Package.swift            # SPM manifest (ViewInspector test dep)
  Sources/
    MeetingTranscriberApp.swift  # @main, menu bar scene
    MenuBarView.swift      # Menu bar dropdown UI
    MenuBarIcon.swift      # Animated waveform menu bar icon (reflects pipeline state)
    SettingsView.swift     # Settings window
    SpeakerNamingView.swift # Speaker naming dialog + AccessibleTextField
    AppPickerView.swift    # App picker for manual recording
    AppPaths.swift         # Centralized paths (ipcDir, dataDir, logSubsystem, speakersDB)
    AppSettings.swift      # @Observable settings (UserDefaults + file-based secrets)
    AXHelper.swift         # Shared accessibility API helper
    NotificationManager.swift # macOS notifications
    KeychainHelper.swift   # Keychain CRUD (legacy/test-only, token now file-based)
    TranscriberStatus.swift # Status + MeetingInfo models
    WhisperKitEngine.swift # Native WhisperKit transcription (CoreML/ANE)
    FluidDiarizer.swift    # CoreML-based speaker diarization via FluidAudio (on-device)
    SpeakerMatcher.swift   # Speaker embedding DB + cosine similarity matching
    DiarizationProcess.swift  # DiarizationProvider protocol + result types
    PipelineQueue.swift    # Decouples recording from post-processing (transcription → diarization → protocol)
    PipelineJob.swift      # Pipeline job model
    ProtocolGenerator.swift   # Protocol generation via Claude CLI + configurable prompt file
    OpenAIProtocolGenerator.swift # OpenAI-compatible API protocol generation (Ollama, LM Studio, etc.)
    WatchLoop.swift        # @MainActor watch loop: detect → record → enqueue PipelineJob
    DualSourceRecorder.swift  # App audio + mic recording (captures startTime in start())
    MeetingDetector.swift  # Window title matching (counts each pattern once per poll)
    AudioMixer.swift       # Multi-format audio loading (WAV/MP3/M4A/MP4 via AVAsset fallback) + mixing to 16kHz mono
    MicRecorder.swift      # Microphone recording via AVAudioEngine
    MuteDetector.swift     # Mute state detection via accessibility API
    Permissions.swift      # Permission checks (mic, screen recording)
    ParticipantReader.swift # Reads meeting participants via accessibility
    MeetingPatterns.swift  # App-specific window title patterns
    UpdateChecker.swift    # GitHub release update checker
    Assets.xcassets        # App icon assets
    Info.plist             # Bundle metadata
  Tests/                   # Swift tests (XCTest + ViewInspector)
    Fixtures/              # Test audio files (two_speakers_de.wav, etc.)
tools/audiotap/            # CATapDescription-based app audio capture (Swift CLI)
  Package.swift            # SPM manifest (macOS 14+)
  Sources/main.swift       # PID → CATapDescription → stdout (interleaved float32)
tools/meeting-simulator/   # Meeting simulator tool for testing
  Package.swift
  Sources/main.swift
scripts/
  build_audiotap.sh        # Build audiotap Swift binary
  build_whisperkit.sh      # Build WhisperKit CLI tool
  build_release.sh         # Build self-contained .app bundle + DMG
  notarize_status.sh       # Check Apple notarization status
  run_app.sh               # Build + sign + launch menu bar app bundle
  generate_test_audio.sh   # Generate 2-speaker test WAV fixture (requires sox)
  generate_test_audio_3speakers.sh  # Generate 3-speaker test WAV fixture (requires sox)
  generate_test_audio_10speakers.sh # Generate 10-speaker test WAV fixture (requires sox)
  generate_menu_bar_gifs.swift      # Generate menu bar animation GIFs
Casks/meeting-transcriber.rb # Homebrew Cask formula
.github/workflows/
  ci.yml                   # CI: Swift tests
  release.yml              # CI: build DMG + GitHub Release on tag push
  pr-labels.yml            # Automatic PR labeling
docs/
  architecture-macos.md        # High-level architecture quick-reference
  menu-bar-*.gif               # Menu bar icon animation GIFs (idle, recording, transcribing, diarizing, protocol)
  plans/
    swift-architecture.md      # Detailed Swift pipeline architecture
FluidAudio/                # Local FluidAudio package (CoreML speaker diarization)
protocols/                 # Output directory (gitignored)
speakers.json              # Saved voice profiles (gitignored, created at runtime)
.env                       # Environment variables (gitignored)
```

## Pipeline

```
Dual-source: App audio + Mic → separate 16kHz audio (WAV/MP3/M4A/MP4) → WhisperKit per track → FluidAudio diarization per track (CoreML/ANE) → merge speakers → Claude CLI / OpenAI-compatible API → Markdown protocol
Single-source: Audio/Video → 16kHz mono (AVAsset fallback for non-WAV) → WhisperKit → FluidAudio diarization → Claude CLI / OpenAI-compatible API → Markdown protocol
```

## Setup

```bash
# Build audiotap Swift binary (app audio capture):
./scripts/build_audiotap.sh

# Run menu bar app (builds automatically):
./scripts/run_app.sh
```

## Key Commands

```bash
# Run menu bar app
./scripts/run_app.sh

# Swift tests
cd app/MeetingTranscriber && swift test

# Build self-contained .app + DMG for distribution
./scripts/build_release.sh
```

## Distribution

The app can be distributed as a self-contained `.app` via Homebrew Cask:

```bash
# Build DMG locally
./scripts/build_release.sh

# Install via Homebrew (once published)
brew tap pasrom/meeting-transcriber
brew install --cask meeting-transcriber
```

**Release workflow:** Push a `v*` tag to trigger `.github/workflows/release.yml` which
builds the DMG on a macOS runner and creates a GitHub Release.

## Git Workflow

Use the `/git-workflow` skill. Commit proactively after every logical unit of work — don't wait for user permission.

- **Conventional Commits:** `<type>(<scope>): <description>` — types: feat, fix, docs, refactor, test, perf, chore, build
- **Scopes:** app, test, build, ci, docs
- **Atomic commits:** one logical change per commit. If you need "and" in the message, split it.
- **Stage explicitly:** `git add <file1> <file2>` — never `git add -A` or `git add .`
- **Verify first:** run tests before committing
- **Commit body:** document the WHY for non-trivial changes (architecture decisions, rejected alternatives)

## Conventions

- All code and UI text in English
- Protocol output generated in German (via Claude prompt)

## Architecture Notes

**Concurrency:**
- `WatchLoop` is `@MainActor`. Tests for this class must also be `@MainActor`.
- `WhisperKitEngine.loadModel()` deduplicates concurrent calls via `loadingTask` — second caller awaits the first's task. Safe to call from multiple places.
- `ProtocolGenerator` uses async process I/O: `terminationHandler` + `withCheckedContinuation` instead of `process.waitUntilExit()`. stdout/stderr are read in detached `Task`s.

**View architecture:**
- `SettingsView` receives `WhisperKitEngine` as a stored property (not `@State`). Constructor: `SettingsView(settings:whisperKitEngine:)`.

**Audio loading:**
- `AudioMixer.loadAudioFileAsFloat32()` tries `AVAudioFile` first, falls back to `AVAsset` for video containers (MP4, MOV) and compressed formats (MP3, M4A).
- `loadAudioFromAVAsset()` extracts audio tracks via `AVAssetReader`, outputs 16kHz Float32 PCM.
- File picker supports WAV, MP3, M4A, MP4, MOV, and other AVAsset-compatible formats.

**Recording:**
- `DualSourceRecorder` captures `recordingStartTime` in `start()`, not in `stop()`.
- Grace period minimum is 1 second (enforced in `AppSettings.endGrace` setter).

**Detection:**
- `MeetingDetector` counts each pattern once per poll — prevents over-counting when multiple windows match the same app.

**Diarization:**
- `FluidDiarizer` uses FluidAudio (CoreML/ANE) for on-device speaker diarization — no HuggingFace token needed.
- **Dual-track diarization:** App and mic tracks are diarized separately. Speaker IDs are prefixed (`R_` for remote/app, `M_` for mic/local), merged, and assigned via `assignSpeakersDualTrack`. Single-source recordings fall back to diarizing the mix with `assignSpeakers`.
- `SpeakerMatcher` stores speaker embeddings in `speakers.json` and matches via cosine similarity (multi-embedding, max 5 per speaker, confidence margin 0.10).
- `DiarizationProvider` protocol enables mock injection in tests.

**Protocol generation:**
- `ProtocolGenerating` protocol with two implementations: `ClaudeCLIProtocolGenerator` and `OpenAIProtocolGenerator`.
- `AppSettings.protocolProvider` enum (`.claudeCLI` / `.openAICompatible`) selects the provider.
- `ProtocolGenerator.loadPrompt()` loads custom prompt from `AppPaths.customPromptFile` (`~/Library/Application Support/MeetingTranscriber/protocol_prompt.md`), falls back to built-in default.
- `OpenAIProtocolGenerator` supports any OpenAI-compatible HTTP API (Ollama, LM Studio, llama.cpp, etc.).

**UI:**
- `MenuBarIcon` renders animated waveform reflecting pipeline state (idle, recording, transcribing, diarizing, protocol).
- `AppPickerView` enables manual recording of any app via app picker.
- `UpdateChecker` checks GitHub releases for newer versions, shows badge on menu bar icon.

## Critical Notes

- audiotap Swift binary must be built: `./scripts/build_audiotap.sh` (uses CATapDescription, macOS 14.2+)
- Screen Recording permission required for **meeting detection** (window titles via `CGWindowListCopyWindowInfo`)
- Audio capture (audiotap) does NOT require Screen Recording — uses CATapDescription (purple dot indicator)
- FluidAudio models are downloaded automatically on first run (~50 MB)
