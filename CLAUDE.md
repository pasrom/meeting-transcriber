# Meeting Transcriber

## Project Structure

```
src/meeting_transcriber/
  __init__.py              # __version__, package docstring
  cli.py                   # Unified CLI entry point (argparse)
  config.py                # PROTOCOL_PROMPT, defaults (shared between platforms)
  protocol.py              # generate_protocol_cli(), save_transcript(), save_protocol()
  diarize.py               # Speaker diarization + voice recognition (pyannote-audio)
  audio/
    mac.py                 # list_audio_apps(), choose_app(), record_audio()
    windows.py             # record_audio() with WASAPI Loopback
  transcription/
    mac.py                 # transcribe() with pywhispercpp
    windows.py             # transcribe() with faster-whisper, get_device()
tests/
  conftest.py              # Shared fixtures, markers
  test_e2e_app_audio.py    # E2E test (automated, incl. real ScreenCaptureKit capture)
pyproject.toml             # Build config, deps, entry points, ruff, pytest
docs/mac_implementation_notes.md  # Implementation notes & pain points
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
/opt/homebrew/bin/python3.14 -m venv .venv
source .venv/bin/activate
pip install -e ".[mac,diarize,dev]"

# Build ProcTap Swift binary with audio fix (required!):
./scripts/build_proctap.sh
```

## Key Commands

```bash
# Lint/format
ruff check src/ tests/ && ruff format src/ tests/

# Run macOS transcriber
transcribe --app "Microsoft Teams" --title "Meeting"
transcribe --file recording.wav --diarize --title "Meeting"

# Run tests
pytest tests/ -v
pytest tests/ -v -m "not slow"

# Run E2E test standalone
python tests/test_e2e_app_audio.py
```

## Conventions

- Use `ruff` for linting/formatting (config in pyproject.toml)
- Always run `ruff check src/ tests/ && ruff format src/ tests/` before committing
- All code and UI text in English
- Protocol output generated in German (via Claude prompt)
- Python 3.14 via homebrew
- Lazy imports for optional dependencies (pyannote, proctap, pywhispercpp)

## Critical Notes

- ProcTap Swift binary must be built manually after pip install
- Screen Recording permission required for app audio capture (System Settings → Privacy & Security)
- ScreenCaptureKit only sees apps with windows + bundle ID
- pyannote diarization requires HuggingFace token + license acceptance for 3 models:
  - pyannote/speaker-diarization-3.1
  - pyannote/segmentation-3.0
  - pyannote/speaker-diarization-community-1
