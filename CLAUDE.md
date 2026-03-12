# Meeting Transcriber

## Project Structure

```
VERSION                    # App version (read by build scripts)
app/MeetingTranscriber/    # Swift macOS menu bar app (SPM)
  Package.swift            # SPM manifest (ViewInspector test dep)
  Sources/
    MeetingTranscriberApp.swift  # @main, menu bar scene
    MenuBarView.swift      # Menu bar dropdown UI
    SettingsView.swift     # Settings window
    SpeakerNamingView.swift # Speaker naming dialog + AccessibleTextField
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
    ProtocolGenerator.swift   # Async Claude CLI protocol generation via Process
    WatchLoop.swift        # @MainActor watch loop: detect → record → enqueue PipelineJob
    DualSourceRecorder.swift  # App audio + mic recording (captures startTime in start())
    MeetingDetector.swift  # Window title matching (counts each pattern once per poll)
    AudioMixer.swift       # Mixes app + mic audio to 16kHz mono WAV
    MicRecorder.swift      # Microphone recording via AVAudioEngine
    MuteDetector.swift     # Mute state detection via accessibility API
    Permissions.swift      # Permission checks (mic, screen recording)
    ParticipantReader.swift # Reads meeting participants via accessibility
    MeetingPatterns.swift  # App-specific window title patterns
    Info.plist             # Bundle metadata
  Tests/                   # Swift tests (XCTest + ViewInspector)
    Fixtures/              # Test audio files (two_speakers_de.wav, etc.)
tools/audiotap/            # CATapDescription-based app audio capture (Swift CLI)
  Package.swift            # SPM manifest (macOS 14+)
  Sources/main.swift       # PID → CATapDescription → stdout (interleaved float32)
scripts/
  build_audiotap.sh        # Build audiotap Swift binary
  build_whisperkit.sh      # Build WhisperKit CLI tool
  build_release.sh         # Build self-contained .app bundle + DMG
  notarize_status.sh       # Check Apple notarization status
  run_app.sh               # Build + sign + launch menu bar app bundle
  generate_test_audio.sh   # Generate 2-speaker test WAV fixture (requires sox)
  generate_test_audio_3speakers.sh  # Generate 3-speaker test WAV fixture (requires sox)
Casks/meeting-transcriber.rb # Homebrew Cask formula
.github/workflows/
  ci.yml                   # CI: Swift tests
  release.yml              # CI: build DMG + GitHub Release on tag push
docs/
  architecture-macos.md        # High-level architecture quick-reference
  plans/
    swift-architecture.md      # Detailed Swift pipeline architecture
protocols/                 # Output directory (gitignored)
speakers.json              # Saved voice profiles (gitignored, created at runtime)
.env                       # Environment variables (gitignored)
```

## Pipeline

```
Dual-source: App audio + Mic → separate 16kHz WAVs → WhisperKit per track → FluidAudio diarization per track (CoreML/ANE) → merge speakers → Claude CLI → Markdown protocol
Single-source: Audio → 16kHz mono WAV → WhisperKit → FluidAudio diarization → Claude CLI → Markdown protocol
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

## Critical Notes

- audiotap Swift binary must be built: `./scripts/build_audiotap.sh` (uses CATapDescription, macOS 14.2+)
- Screen Recording permission required for **meeting detection** (window titles via `CGWindowListCopyWindowInfo`)
- Audio capture (audiotap) does NOT require Screen Recording — uses CATapDescription (purple dot indicator)
- FluidAudio models are downloaded automatically on first run (~50 MB)
