# Meeting Transcriber

[![CI](https://github.com/pasrom/meeting-transcriber/actions/workflows/ci.yml/badge.svg)](https://github.com/pasrom/meeting-transcriber/actions/workflows/ci.yml)

A native macOS menu bar app that automatically detects, records, transcribes, and summarizes your meetings — fully on-device, no cloud transcription.

```
Meeting Detected → App Audio + Mic → WhisperKit per track (CoreML) → FluidAudio Diarization per track (CoreML) → Claude CLI / OpenAI-compatible API → Markdown Protocol
File Import → Audio/Video (WAV, MP3, M4A, MP4, MKV, WebM, OGG) → 16kHz mono conversion → WhisperKit → FluidAudio Diarization → Protocol
```

---

## Features

- **Automatic meeting detection** — Recognizes Teams, Zoom, and Webex meetings via window title polling
- **Dual audio recording** — App audio ([CATapDescription](https://developer.apple.com/documentation/coreaudio/catap)) + microphone simultaneously
- **On-device transcription** — [WhisperKit](https://github.com/argmaxinc/WhisperKit) running on CoreML/Apple Neural Engine
- **On-device speaker diarization** — [FluidAudio](https://github.com/FluidAudio) via CoreML/ANE — no HuggingFace token needed
- **Dual-track diarization** — App and mic tracks diarized separately for clean speaker separation without echo interference
- **Speaker recognition** — Voice embeddings stored across meetings, matched via cosine similarity
- **AI protocol generation** — Structured Markdown via [Claude Code CLI](https://docs.anthropic.com/en/docs/claude-code) or OpenAI-compatible APIs (Ollama, LM Studio, etc.)
- **Configurable protocol prompt** — Custom prompt file support (`~/Library/Application Support/MeetingTranscriber/protocol_prompt.md`)
- **Manual recording** — Record any app via app picker, not just detected meetings
- **Multi-format input** — Supports WAV, MP3, M4A, MP4, and with ffmpeg also MKV, WebM, OGG
- **Update checker** — Notifies when a new version is available
- **Background processing** — PipelineQueue runs transcription and protocol generation independently from recording
- **Distribution** — Install via Homebrew Cask or build from source

---

## Prerequisites

- macOS 14.2+ (required for CATapDescription audio capture)
- **One of:**
  - [Claude Code CLI](https://docs.anthropic.com/en/docs/claude-code) — installed and logged in (`claude --version`)
  - An OpenAI-compatible API endpoint (e.g. [Ollama](https://ollama.com), LM Studio, llama.cpp) — configure in Settings

No HuggingFace token needed — FluidAudio downloads its models automatically on first run (~50 MB).

### Optional: ffmpeg for extra formats

Install ffmpeg to enable MKV, WebM, and OGG support:

```bash
brew install ffmpeg
```

The app detects ffmpeg automatically. Status is shown in Settings → About.

### Using Ollama as provider

1. Install Ollama: `brew install ollama`
2. Pull a model: `ollama pull llama3.1` (or any model that fits your hardware)
3. Start the server: `ollama serve` (runs on `http://localhost:11434` by default)
4. In the app's Settings, select **OpenAI-Compatible API** as provider and set:
   - **Endpoint:** `http://localhost:11434/v1/chat/completions`
   - **Model:** `llama3.1` (must match the pulled model name)

---

## Installation

### Via Homebrew Cask (recommended)

```bash
brew tap pasrom/meeting-transcriber
brew install --cask meeting-transcriber
```

### Build from source

```bash
git clone https://github.com/pasrom/meeting-transcriber
cd meeting-transcriber
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

## Menu Bar Icon

The app uses an animated waveform icon in the menu bar that reflects the current pipeline stage:

<p>
<img src="docs/menu-bar-idle.gif" width="80" alt="Idle">&nbsp;&nbsp;
<img src="docs/menu-bar-recording.gif" width="80" alt="Recording">&nbsp;&nbsp;
<img src="docs/menu-bar-transcribing.gif" width="80" alt="Transcribing">&nbsp;&nbsp;
<img src="docs/menu-bar-diarizing.gif" width="80" alt="Diarizing">&nbsp;&nbsp;
<img src="docs/menu-bar-protocol.gif" width="80" alt="Protocol">
</p>

**Idle** → **Recording** (bars bounce) → **Transcribing** (bars morph to text) → **Diarizing** (bars split into groups) → **Protocol** (lines appear sequentially)

---

## Usage

Launch the app — it sits in your menu bar. When a supported meeting is detected, recording starts automatically. When the meeting ends, the pipeline runs in the background: transcription → diarization → protocol generation.

You can also batch-process existing audio and video files via the menu (⌘P) — supported formats: WAV, MP3, M4A, MP4 (and MKV, WebM, OGG when ffmpeg is installed).

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
| `claude not found` | Install Claude Code CLI, run `claude --version` — or switch to OpenAI-compatible provider in Settings |
| No meeting detected | Grant Screen Recording permission (System Settings → Privacy & Security) |
| No app audio | Requires macOS 14.2+ for CATapDescription audio capture |
| Empty transcription | Check that the file contains an audio track — the app converts to 16 kHz mono automatically |
| Models not loading | FluidAudio models download on first run; check internet connectivity |
| OpenAI-compatible API connection failed | Verify the endpoint URL and that the local model server is running |

---

## License

[MIT](LICENSE)
