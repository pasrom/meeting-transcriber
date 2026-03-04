# Meeting Transcriber

## Project Structure

```
src/meeting_transcriber/
  __init__.py              # __version__, package docstring
  cli.py                   # Unified CLI entry point (argparse)
  config.py                # PROTOCOL_PROMPT, defaults, IPC paths (~/.meeting-transcriber/)
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
    SpeakerCountView.swift # Speaker count dialog
    PythonProcess.swift    # Launches/manages Python transcribe process
    StatusMonitor.swift    # Polls ~/.meeting-transcriber/status.json
    IPCManager.swift       # Read/write speaker request/response JSON
    NotificationManager.swift # macOS notifications
    AppSettings.swift      # @Observable settings (UserDefaults + Keychain)
    KeychainHelper.swift   # Keychain CRUD for HF token
    TranscriberStatus.swift # Status + MeetingInfo models
    SpeakerRequest.swift   # Speaker IPC models
    Info.plist             # Bundle metadata
  Tests/                   # 218 Swift tests (XCTest + ViewInspector)
scripts/
  build_proctap.sh         # Build ProcTap Swift binary with audio fix
  run_app.sh               # Build + sign + launch menu bar app bundle
  generate_test_audio.sh   # Generate 2-speaker test WAV fixture
  generate_test_audio_3speakers.sh  # Generate 3-speaker test WAV fixture
  dump_teams_ax.py         # Debug Teams accessibility API
tests/
  conftest.py              # Shared fixtures, markers
  test_e2e_app_audio.py    # E2E test (automated, incl. real ScreenCaptureKit capture)
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
patches/screencapture-audio/ # ProcTap audio interleaving fix (Swift)
pyproject.toml             # Build config, deps, entry points, ruff, pytest
docs/
  mac_implementation_notes.md  # Implementation notes & pain points
  dmg_distribution_plan.md     # DMG distribution planning
protocols/                 # Output directory (gitignored)
speakers.json              # Saved voice profiles (gitignored, created at runtime)
.env                       # HF_TOKEN for diarization (gitignored)
```

## Pipeline

```
App audio (ProcTap) + Microphone → mix → 16kHz mono WAV → Whisper → [pyannote diarization] → Claude CLI → Markdown protocol
```

## Setup

```bash
# Python
/opt/homebrew/bin/python3.14 -m venv .venv
source .venv/bin/activate
pip install -e ".[mac,diarize,dev]"

# Build ProcTap Swift binary with audio fix (required!):
./scripts/build_proctap.sh

# Swift menu bar app
cd app/MeetingTranscriber && swift build -c release
```

## Key Commands

```bash
# Lint/format
ruff check src/ tests/ && ruff format src/ tests/

# Run macOS transcriber (CLI)
transcribe --app "Microsoft Teams" --title "Meeting"
transcribe --file recording.wav --diarize --title "Meeting"

# Run menu bar app
./scripts/run_app.sh

# Python tests
pytest tests/ -v
pytest tests/ -v -m "not slow"

# Swift tests (218 tests)
cd app/MeetingTranscriber && swift test

# Run E2E test standalone
python tests/test_e2e_app_audio.py
```

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
- Lazy imports for optional dependencies (pyannote, proctap, pywhispercpp)

## Critical Notes

- ProcTap Swift binary must be built manually after pip install
- Screen Recording permission required **twice**: for Terminal (CLI use) AND for MeetingTranscriber.app (menu bar app) — without it, `CGWindowListCopyWindowInfo` returns no window titles and meetings are not detected
- ScreenCaptureKit only sees apps with windows + bundle ID
- pyannote diarization requires HuggingFace token + license acceptance for 3 models:
  - pyannote/speaker-diarization-3.1
  - pyannote/segmentation-3.0
  - pyannote/speaker-diarization-community-1
- Swift ↔ Python IPC via JSON files in `~/.meeting-transcriber/` (status, speaker requests/responses)
