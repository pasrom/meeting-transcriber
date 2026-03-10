# Meeting Transcriber

[![CI](https://github.com/meanstone/Transcriber/actions/workflows/ci.yml/badge.svg)](https://github.com/meanstone/Transcriber/actions/workflows/ci.yml)

A native macOS menu bar app that automatically detects, records, transcribes, and summarizes your meetings — fully on-device, no cloud transcription.

```
Meeting Detected → App Audio + Mic → WhisperKit per track (CoreML) → FluidAudio Diarization per track (CoreML) → Claude CLI → Markdown Protocol
```

---

## Features

- **Automatic meeting detection** — Recognizes Teams, Zoom, and Webex meetings via window title polling
- **Dual audio recording** — App audio ([CATapDescription](https://developer.apple.com/documentation/coreaudio/catap)) + microphone simultaneously
- **On-device transcription** — [WhisperKit](https://github.com/argmaxinc/WhisperKit) running on CoreML/Apple Neural Engine
- **On-device speaker diarization** — [FluidAudio](https://github.com/FluidAudio) via CoreML/ANE — no HuggingFace token needed
- **Dual-track diarization** — App and mic tracks diarized separately for clean speaker separation without echo interference
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

### Via Homebrew Cask (recommended)

```bash
brew tap pasrom/meeting-transcriber
brew install --cask meeting-transcriber
```

### Build from source

```bash
git clone https://github.com/meanstone/Transcriber
cd Transcriber
./scripts/build_audiotap.sh
cd app/MeetingTranscriber && swift build -c release
cd ../..
./scripts/run_app.sh
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

Launch the app — it sits in your menu bar. When a supported meeting is detected, recording starts automatically. When the meeting ends, the pipeline runs in the background: transcription → diarization → protocol generation.

You can also batch-process existing audio files via the menu (⌘P).

---

## Output

Files are saved to `~/Library/Application Support/MeetingTranscriber/protocols/`:

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
