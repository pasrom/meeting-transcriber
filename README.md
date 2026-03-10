# Meeting Transcriber

[![CI](https://github.com/meanstone/Transcriber/actions/workflows/ci.yml/badge.svg)](https://github.com/meanstone/Transcriber/actions/workflows/ci.yml)

A native macOS menu bar app that automatically detects, records, transcribes, and summarizes your meetings — fully on-device, no cloud transcription.

```
Meeting Detected → App Audio + Mic → Mix → WhisperKit (CoreML) → FluidAudio Diarization (CoreML) → Claude CLI → Markdown Protocol
```

---

## Features

- **Automatic meeting detection** — Recognizes Teams, Zoom, and Webex meetings via window title polling
- **Dual audio recording** — App audio ([CATapDescription](https://developer.apple.com/documentation/coreaudio/catap)) + microphone simultaneously
- **On-device transcription** — [WhisperKit](https://github.com/argmaxinc/WhisperKit) running on CoreML/Apple Neural Engine
- **On-device speaker diarization** — [FluidAudio](https://github.com/FluidAudio) via CoreML/ANE — no HuggingFace token needed
- **Hybrid speaker identification** — Dual-source recording identifies the local speaker; FluidAudio distinguishes remote speakers
- **Speaker recognition** — Voice embeddings stored across meetings, matched via cosine similarity
- **AI protocol generation** — Structured Markdown via [Claude Code CLI](https://docs.anthropic.com/en/docs/claude-code)
- **Background processing** — PipelineQueue runs transcription and protocol generation independently from recording
- **Distribution** — Install via Homebrew Cask or build from source

---

## Prerequisites

- macOS 14.2+ (required for CATapDescription audio capture)
- [Claude Code CLI](https://docs.anthropic.com/en/docs/claude-code) — installed and logged in (`claude --version`)

No HuggingFace token needed — FluidAudio downloads its models automatically on first run (~50 MB).

---

## Installation

### Native App (recommended)

```bash
# Via Homebrew Cask
brew tap pasrom/meeting-transcriber
brew install --cask meeting-transcriber
```

Or build from source:

```bash
git clone https://github.com/meanstone/Transcriber
cd Transcriber
./scripts/build_audiotap.sh
cd app/MeetingTranscriber && swift build -c release
cd ../..
./scripts/run_app.sh
```

### Python CLI (alternative)

For manual transcription without the menu bar app:

```bash
git clone https://github.com/meanstone/Transcriber
cd Transcriber
python3 -m venv .venv
source .venv/bin/activate
pip install -e ".[mac,dev]"
./scripts/build_audiotap.sh
```

---

## Permissions

| Permission | Required for | Notes |
|------------|-------------|-------|
| Screen Recording | Meeting detection (window titles) | System Settings → Privacy & Security |
| Microphone | Mic recording | Prompted on first use |
| Accessibility | Mute detection, participant reading (Teams) | System Settings → Privacy & Security |
| App audio capture | — | No permission needed (purple dot indicator only) |

---

## Usage

### Menu Bar App

Launch the app — it sits in your menu bar. When a supported meeting is detected, recording starts automatically. When the meeting ends, the pipeline runs in the background: transcription → diarization → protocol generation.

You can also batch-process existing audio files via the menu (⌘P).

### Python CLI

```bash
# Record app audio + microphone
transcribe --app "Microsoft Teams" --title "Sprint Review"

# Microphone only
transcribe --mic-only --title "Interview"

# Transcribe audio file
transcribe --file recording.mp3 --title "Sprint Review"

# Protocol from existing transcript
transcribe --file protocols/transcript.txt --title "Standup"

# List available apps
transcribe --list-apps
```

Press **Enter** to stop a live recording.

---

## CLI Reference

| Flag | Description |
|------|-------------|
| `--file, -f` | Audio file or transcript (.txt) |
| `--title, -t` | Meeting title (default: "Meeting") |
| `--output-dir, -o` | Output directory (default: `./protocols`) |
| `--model, -m` | Whisper model (default: `large-v3-turbo-q5_0`) |
| `--app, -a` | App name for audio capture |
| `--pid` | Process ID for app audio |
| `--list-apps` | List running apps and exit |
| `--mic-only` | Microphone only, no app audio |
| `--list-mics` | List available microphone devices and exit |
| `--mic` | Microphone device index or name substring |
| `--diarize` | Enable speaker diarization |
| `--speakers` | Expected number of speakers |

---

## Output

Files are saved to `~/Library/Application Support/MeetingTranscriber/protocols/` (app) or `./protocols/` (CLI):

| File | Content |
|------|---------|
| `20260225_1400_meeting.txt` | Raw transcript |
| `20260225_1400_meeting.md` | Structured protocol |

**Protocol structure:** Summary, Participants, Topics Discussed, Decisions, Tasks (with responsible person, deadline, priority), Open Questions, Full Transcript.

---

## Troubleshooting

| Problem | Solution |
|---------|----------|
| `claude not found` | Install Claude Code CLI, run `claude --version` |
| No meeting detected | Grant Screen Recording permission (System Settings → Privacy & Security) |
| No app audio | Build audiotap: `./scripts/build_audiotap.sh` (macOS 14.2+ required) |
| Empty transcription | Ensure audio is 16 kHz mono WAV — WhisperKit requires this format |
| Models not loading | FluidAudio models download on first run; check internet connectivity |

---

## License

[MIT](LICENSE)
