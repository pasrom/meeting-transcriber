# Meeting Transcriber

## Project Structure

```
src/meeting_transcriber/
  __init__.py              # __version__, package docstring
  cli.py                   # Unified CLI entry point (argparse)
  config.py                # PROTOCOL_PROMPT, defaults, IPC paths, get_data_dir()
  protocol.py              # generate_protocol_cli(), save_transcript(), save_protocol()
  diarize.py               # Speaker diarization + voice recognition (pyannote-audio)
  status.py                # Atomic JSON status emitter for menu bar app
  audio/
    mac.py                 # list_audio_apps(), choose_app(), record_audio()
    windows.py             # record_audio() with WASAPI Loopback
  transcription/
    mac.py                 # transcribe() with pywhispercpp (single + dual-source)
    windows.py             # transcribe() with faster-whisper, get_device()
  watch/
    detector.py            # MeetingDetector — window title matching
    mute_detector.py       # Mute state detection via accessibility API
    patterns.py            # App-specific window title patterns
    watcher.py             # Main watch loop: detect → record → transcribe → protocol
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
    KeychainHelper.swift   # Keychain CRUD (legacy, token now file-based)
    TranscriberStatus.swift # Status + MeetingInfo models
    WhisperKitEngine.swift # Native WhisperKit transcription (CoreML/ANE)
    FluidDiarizer.swift    # CoreML-based speaker diarization via FluidAudio (on-device)
    SpeakerMatcher.swift   # Speaker embedding DB + cosine similarity matching
    DiarizationProcess.swift  # DiarizationProvider protocol + result types
    PipelineQueue.swift    # Decouples recording from post-processing (transcription → diarization → protocol)
    PipelineJob.swift      # Pipeline job model
    ProtocolGenerator.swift   # Async Claude CLI protocol generation via Process
    WatchLoop.swift        # @MainActor watch loop: detect → record → transcribe → protocol
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
tools/audiotap/            # CATapDescription-based app audio capture (Swift CLI)
  Package.swift            # SPM manifest (macOS 14+)
  Sources/main.swift       # PID → CATapDescription → stdout (interleaved float32)
scripts/
  build_audiotap.sh        # Build audiotap Swift binary
  build_release.sh         # Build self-contained .app bundle + DMG
  run_app.sh               # Build + sign + launch menu bar app bundle
  generate_test_audio.sh   # Generate 2-speaker test WAV fixture
  generate_test_audio_3speakers.sh  # Generate 3-speaker test WAV fixture
  dump_teams_ax.py         # Debug Teams accessibility API
tests/
  conftest.py              # Shared fixtures, markers
  test_e2e_app_audio.py    # E2E test (automated, incl. real audiotap capture)
  test_audio_mac.py        # Audio recording tests
  test_diarize.py          # Diarization unit tests
  test_dual_source.py      # Dual-source transcription tests
  test_e2e_diarize.py      # E2E diarization test
  test_mute_detector.py    # Mute detector tests
  test_protocol.py         # Protocol generation tests
  test_speaker_ipc.py      # Speaker IPC unit tests
  test_speaker_ipc_e2e.py  # Speaker IPC E2E tests
  test_watch_detector.py   # Meeting detector tests
  test_watcher.py          # Watcher loop tests
  fixtures/                # Test audio files (two_speakers_de.wav, etc.)
pyproject.toml             # Build config, deps, entry points, ruff, pytest
entitlements.plist         # macOS entitlements for notarized builds
Casks/meeting-transcriber.rb # Homebrew Cask formula
.github/workflows/release.yml # CI: build DMG + GitHub Release on tag push
docs/
  mac_implementation_notes.md  # Implementation notes & pain points
  dmg_distribution_plan.md     # DMG distribution planning
protocols/                 # Output directory (gitignored)
speakers.json              # Saved voice profiles (gitignored, created at runtime)
.env                       # Environment variables (gitignored)
```

## Pipeline

```
Native Swift pipeline (menu bar app):
  App audio (audiotap/CATapDescription) + Microphone → mix → 16kHz mono WAV → WhisperKit (CoreML/ANE) → FluidAudio diarization (CoreML/ANE) → Claude CLI → Markdown protocol

Python CLI pipeline:
  App audio (audiotap/CATapDescription) + Microphone → mix → 16kHz mono WAV → Whisper (pywhispercpp) → Claude CLI → Markdown protocol
```

## Setup

```bash
# Python
/opt/homebrew/bin/python3.14 -m venv .venv
source .venv/bin/activate
pip install -e ".[mac,dev]"

# Build audiotap Swift binary (app audio capture):
./scripts/build_audiotap.sh

# Swift menu bar app
cd app/MeetingTranscriber && swift build -c release
```

## Key Commands

```bash
# Lint/format
ruff check src/ tests/ && ruff format src/ tests/

# Run macOS transcriber (CLI)
transcribe --app "Microsoft Teams" --title "Meeting"
transcribe --file recording.wav --title "Meeting"

# Run menu bar app
./scripts/run_app.sh

# Python tests
pytest tests/ -v
pytest tests/ -v -m "not slow"

# Swift tests (~250 tests)
cd app/MeetingTranscriber && swift test

# Run E2E test standalone
python tests/test_e2e_app_audio.py

# Build self-contained .app + DMG for distribution
./scripts/build_release.sh

# Test bundle-aware paths without building full bundle
MEETING_TRANSCRIBER_BUNDLED=1 transcribe --file test.wav --title "Test"
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

**Bundle mode:** When `MEETING_TRANSCRIBER_BUNDLED=1` is set, all output files go to
`~/Library/Application Support/MeetingTranscriber/` instead of CWD. The Swift app sets
this automatically when running from a bundle.

**Release workflow:** Push a `v*` tag to trigger `.github/workflows/release.yml` which
builds the DMG on a macOS-14 runner and creates a GitHub Release.

## Git Workflow

Use the `/git-workflow` skill. Commit proactively after every logical unit of work — don't wait for user permission.

- **Conventional Commits:** `<type>(<scope>): <description>` — types: feat, fix, docs, refactor, test, perf, chore, build
- **Scopes:** cli, audio, transcription, protocol, diarize, watch, config, app (Swift), test
- **Atomic commits:** one logical change per commit. If you need "and" in the message, split it.
- **Stage explicitly:** `git add <file1> <file2>` — never `git add -A` or `git add .`
- **Verify first:** run `ruff check src/ tests/` and tests before committing
- **Commit body:** document the WHY for non-trivial changes (architecture decisions, rejected alternatives)

## Conventions

- Use `ruff` for linting/formatting (config in pyproject.toml)
- Always run `ruff check src/ tests/ && ruff format src/ tests/` before committing
- All code and UI text in English
- Protocol output generated in German (via Claude prompt)
- Python 3.14 via homebrew
- Lazy imports for optional dependencies (pyannote, pywhispercpp)

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
- `FluidDiarizer` uses FluidAudio (CoreML/ANE) for on-device speaker diarization — no HuggingFace token or Python subprocess needed.
- `SpeakerMatcher` stores speaker embeddings in `speakers.json` and matches via cosine similarity. Migrates old pyannote-format DB automatically.
- `DiarizationProvider` protocol enables mock injection in tests.

## Critical Notes

- audiotap Swift binary must be built: `./scripts/build_audiotap.sh` (uses CATapDescription, macOS 14.2+)
- Screen Recording permission required for **meeting detection** (window titles via `CGWindowListCopyWindowInfo`) — for Terminal (CLI) AND MeetingTranscriber.app
- Audio capture (audiotap) does NOT require Screen Recording — uses CATapDescription (purple dot indicator)
- FluidAudio models are downloaded automatically on first run (~50 MB)
