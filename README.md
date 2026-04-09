# Meeting Transcriber

[![CI](https://github.com/pasrom/meeting-transcriber/actions/workflows/ci.yml/badge.svg)](https://github.com/pasrom/meeting-transcriber/actions/workflows/ci.yml)

A native macOS menu bar app that automatically detects, records, transcribes, and summarizes your meetings — fully on-device, no cloud transcription.

```
         ┌──────────────────────┐         ┌──────────────────────┐
         │   Meeting Detected   │         │     File Import      │
         │  Teams / Zoom / Webex│         │ WAV MP3 M4A MP4 MKV  │
         └──────────┬───────────┘         └──────────┬───────────┘
                    │                                │
                    ▼                                ▼
         ┌──────────────────────┐         ┌──────────────────────┐
         │   Dual Recording     │         │   16kHz Mono Convert │
         │  App Audio + Mic     │         │  AVAudioFile/ffmpeg  │
         │  (16kHz per track)   │         │                      │
         └──────────┬───────────┘         └──────────┬───────────┘
                    │                                │
                    └────────────────┬───────────────┘
                                     ▼
                        ┌──────────────────────────┐
                        │   Transcription Engine   │
                        │ ┌──────────┬───────────┐ │
                        │ │ Whisper  │FluidAudio │ │
                        │ │   Kit    │ Parakeet  │ │
                        │ │          │ Qwen3-ASR │ │
                        │ └──────────┴───────────┘ │
                        │      CoreML / ANE        │
                        └────────────┬─────────────┘
                                     ▼
                         ┌────────────────────────┐
                         │  Speaker Diarization   │
                         │  FluidAudio CoreML/ANE │
                         │  + Speaker Recognition │
                         └───────────┬────────────┘
                                     ▼
                         ┌────────────────────────┐
                         │  Protocol Generation   │
                         │  Claude CLI / OpenAI   │
                         └───────────┬────────────┘
                                     ▼
                         ┌────────────────────────┐
                         │   Markdown Protocol    │
                         │  Summary · Decisions   │
                         │  Tasks · Transcript    │
                         └────────────────────────┘
```

---

## Features

- **Automatic meeting detection** — Recognizes Teams, Zoom, and Webex meetings via window title polling
- **Dual audio recording** — App audio ([CATapDescription](https://developer.apple.com/documentation/coreaudio/catap)) + microphone simultaneously
- **On-device transcription** — Three engines, selectable in Settings:
  - [WhisperKit](https://github.com/argmaxinc/WhisperKit) — 99+ languages, ~1 GB model
  - [Parakeet TDT v3](https://github.com/FluidInference/FluidAudio) (NVIDIA) — 25 EU languages, ~50 MB model, ~10× faster, custom vocabulary support (CTC boosting)
  - [Qwen3-ASR](https://github.com/FluidInference/FluidAudio) (Alibaba) — 30 languages, ~1.75 GB model, macOS 15+
- **On-device speaker diarization** — [FluidAudio](https://github.com/FluidInference/FluidAudio) via CoreML/ANE — no HuggingFace token needed; two modes: standard (`OfflineDiarizer`) and overlap-aware (`Sortformer`)
- **Dual-track diarization** — App and mic tracks diarized separately for clean speaker separation without echo interference
- **Speaker recognition** — Voice embeddings stored across meetings, matched via cosine similarity
- **VAD preprocessing** — Optional silence trimming via FluidAudio Silero v6 before transcription, with automatic timestamp remapping
- **AI protocol generation** — Structured Markdown via [Claude Code CLI](https://docs.anthropic.com/en/docs/claude-code), OpenAI-compatible APIs (Ollama, LM Studio, etc.), or disabled (save transcript only)
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

No HuggingFace token needed — FluidAudio and WhisperKit download their models automatically on first run.

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

### Pre-release (RC) via Homebrew

```bash
brew tap pasrom/meeting-transcriber
brew install --cask meeting-transcriber@beta
```

> Note: The stable and beta casks conflict — uninstall one before installing the other.

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

### Permission problem badge

<p>
<img src="docs/menu-bar-permission.gif" width="80" alt="Permission problem">
</p>

A red exclamation mark in the bottom-right corner is overlaid on top of the current icon (idle, recording, transcribing, …) whenever one of the required permissions is missing or broken. It means at least one of the following is not in a working state:

- **Microphone** — denied, or granted but the capture engine can't open the device
- **Screen Recording** — denied, or granted but `CGWindowListCopyWindowInfo` returns no window titles (TCC state out of sync)
- **Accessibility** — denied, or granted but the AX API refuses to read Teams participant/mute info

The health check distinguishes *denied* from *broken*. "Broken" usually means the permission is toggled on in System Settings but macOS hasn't actually wired it through — the fix is to toggle the permission off and on again for Meeting Transcriber under **System Settings → Privacy & Security**. Open the menu bar dropdown to see which specific permission is affected; a notification is also posted when the state changes.

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
| Models not loading | Models download on first run (WhisperKit ~1 GB, Parakeet ~50 MB, Qwen3 ~1.75 GB); check internet connectivity |
| OpenAI-compatible API connection failed | Verify the endpoint URL and that the local model server is running |

---

## License

[MIT](LICENSE)
