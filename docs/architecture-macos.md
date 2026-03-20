# Meeting Transcriber — macOS Architecture

## Overview

Native SwiftUI menu bar application that orchestrates meeting detection, recording, transcription, diarization, and protocol generation. Runs a background watch loop (`WatchLoop`) polling for active meetings and implementing a complete end-to-end pipeline.

**Key pattern:** Observable state models (`@Observable`) with PipelineQueue for decoupled post-processing.

---

## Pipeline

```
Meeting Window Detected (CGWindowListCopyWindowInfo)
  → DualSourceRecorder (AudioTapLib + mic)
    → AudioMixer (resample 48kHz → 16kHz)
      → FluidTranscriptionEngine (CoreML/ANE transcription)
        → [FluidDiarizer (CoreML/ANE speaker diarization)]
          → ProtocolGenerator (Claude CLI)
            → Markdown protocol + transcript
```

---

## Source Files

### App Entry & UI

| File | Role |
|------|------|
| `MeetingTranscriberApp.swift` | `@main` entry point, scene management, WatchLoop lifecycle |
| `MenuBarView.swift` | Menu bar dropdown (state, actions, meeting info) |
| `SettingsView.swift` | Settings window (apps, recording, transcription, diarization) |
| `SpeakerNamingView.swift` | Speaker naming dialog after diarization |
| `AppSettings.swift` | `@Observable` settings persisted to UserDefaults |

### Core Pipeline

| File | Role |
|------|------|
| `WatchLoop.swift` | Main orchestrator: detect → record → enqueue PipelineJob |
| `MeetingDetector.swift` | Window polling, pattern matching, confirmation counting, cooldown |
| `MeetingPatterns.swift` | Regex patterns for Teams, Zoom, Webex |
| `DualSourceRecorder.swift` | Orchestrates AudioTapLib capture + mic, mixes tracks |
| `FluidTranscriptionEngine.swift` | FluidAudio Parakeet transcription (single/dual-source/segments) |
| `PipelineQueue.swift` | Decouples recording from post-processing, sequential job pipeline |
| `PipelineJob.swift` | Pipeline job model (waiting → transcribing → diarizing → generatingProtocol → done) |
| `FluidDiarizer.swift` | On-device speaker diarization via FluidAudio CoreML/ANE |
| `SpeakerMatcher.swift` | Speaker embedding DB + cosine similarity matching |
| `DiarizationProcess.swift` | Diarization result types, DiarizationProvider protocol, speaker assignment (standard + dual-track) |
| `ProtocolGenerator.swift` | Claude CLI invocation, stream-json parsing |

### Audio Processing

| File | Role |
|------|------|
| `AudioMixer.swift` | Resampling, mixing, echo suppression, mute masking, WAV I/O |
| `MicRecorder.swift` | Microphone recording via AVAudioEngine |
| `MuteDetector.swift` | Teams mute state via Accessibility API |
| `tools/audiotap/Sources/` | AudioTapLib — CATapDescription-based app audio capture (SPM library) |

### Support

| File | Role |
|------|------|
| `TranscriberStatus.swift` | Status + state enum models |
| `AppPaths.swift` | Centralized path constants (ipcDir, dataDir, logSubsystem, speakersDB) |
| `AXHelper.swift` | Shared accessibility API helper (MuteDetector + ParticipantReader) |
| `NotificationManager.swift` | macOS notifications |
| `KeychainHelper.swift` | Legacy keychain CRUD (token now file-based) |
| `Permissions.swift` | Mic/accessibility permissions, project root detection |
| `ParticipantReader.swift` | Teams participant extraction via Accessibility API |

---

## State Machine

```
WatchLoop:     idle → watching → recording → watching (enqueues PipelineJob)
PipelineQueue: waiting → transcribing → [diarizing] → generatingProtocol → done (60s auto-remove)
                                                                            ↳ error
```

**Transitions** are observable via `WatchLoop.state` and `PipelineQueue.jobs`, triggering:
- Menu bar icon/label updates
- macOS notifications (recording started, protocol ready, error)

---

## Audio Pipeline

### Capture

```
AudioTapLib (CATapDescription)
├─ Input: App PID → CoreAudio process tap → aggregate device
├─ Output: Interleaved float32 stereo → FileHandle (raw PCM)
├─ Mic: AVAudioEngine → mono WAV file (MicCaptureHandler)
└─ Metadata: micDelay, actualSampleRate via AudioCaptureResult
```

**Key:** CATapDescription requires NO Screen Recording permission (purple dot indicator only). Handles output device changes by recreating tap automatically.

### Processing (DualSourceRecorder.stop())

```
Raw float32 stereo → mono (channel average)
  → Save app.wav (at actual hardware rate)
  → Resample to 48kHz if hardware rate differs
  → Load mic.wav
  → Apply mute mask (zero mic during muted periods)
  → Echo suppression (RMS-based gate, 20ms windows)
  → Delay alignment (prepend zeros by MIC_DELAY)
  → Mix (average tracks)
  → Save mix.wav (48kHz mono)
```

### Resampling for Transcription

```
48kHz WAV → AudioMixer.resample(from: 48000, to: 16000) → 16kHz WAV
```

FluidAudio requires 16kHz mono input. Both app and mic tracks are resampled before transcription.

---

## Transcription

### FluidTranscriptionEngine

- **Model:** `parakeet-tdt-0.6b-v2-coreml` (CoreML/ANE via FluidAudio)
- **Pre-loading:** Model downloaded and loaded at app launch
- **Lazy fallback:** `ensureModel()` loads on-demand if not ready
- **Language:** English only (Parakeet TDT V2)
- **Vocabulary boosting:** Optional CTC-based custom vocabulary via `configureVocabulary()`

### Modes

1. **Single source:** `transcribeSegments(audioPath:)` → `[TimestampedSegment]` with start/end/text
2. **Dual source:** `transcribeSegments(appAudio:)` + `transcribeSegments(micAudio:)` → `mergeDualSourceSegments(appSegments:micSegments:)` → `[TimestampedSegment]` merged by timestamp
   - App segments labeled "Remote"
   - Mic segments labeled with user's mic name (default "Me")

### Post-processing

- **Token grouping:** SentencePiece tokens grouped into sentences based on punctuation (`.?!`) and pauses (>1.0s)
- **SentencePiece normalization:** `▁` markers converted to spaces

---

## Diarization

### FluidDiarizer (On-device)

On-device speaker diarization using FluidAudio (CoreML/ANE). No HuggingFace token or Python subprocess needed. Models downloaded automatically on first run (~50 MB).

Flow: `FluidDiarizer.run(audioPath, numSpeakers)` → `OfflineDiarizerManager` → `DiarizationResult` with segments, speaking times, and speaker embeddings.

### Speaker Matching

`SpeakerMatcher` matches diarization speaker embeddings against a persistent speaker database (`speakers.json`) using cosine similarity (threshold: 0.40, confidence margin: 0.10). Stores up to 5 embeddings per speaker (FIFO). Enables recognition of returning speakers across meetings.

### Speaker Assignment

For each transcript segment, find the diarization segment with the longest temporal overlap:
```
overlap = max(0, min(seg.end, dSeg.end) - max(seg.start, dSeg.start))
```
No overlap → nearest-segment fallback by gap distance. Only if no diarization segments exist → "UNKNOWN".

### Dual-Track Diarization

When dual-source recording (app + mic) is available:
1. Transcribe app/mic tracks separately → "Remote" / micLabel segments
2. Diarize app track and mic track separately via FluidAudio
3. `mergeDualTrackDiarization()` — prefix speaker IDs (`R_` for remote, `M_` for local), merge segments by time
4. `preMatchParticipants()` — heuristic assignment of Teams participants to unmatched speakers by speaking time
5. Speaker naming UI — all speakers editable with participant suggestions
6. `assignSpeakersDualTrack()` — app segments matched against app diarization, mic segments against mic diarization

**Single-source fallback:** When only mix audio is available, diarize the mix and use `assignSpeakers()` with nearest-segment fallback.

### Speaker Naming UI

`SpeakerNamingView` shown when diarization finds speakers. Each row shows label, auto-matched name, speaking time, and audio playback. All rows are editable. Supports re-run with different speaker count.

---

## Protocol Generation

### Claude CLI Invocation

```bash
/usr/bin/env claude -p - --output-format stream-json --verbose --model sonnet
```

- **Input:** German protocol prompt + transcript piped to stdin
- **Output:** Stream-json parsed line-by-line (content_block_delta + assistant message)
- **Environment:** `CLAUDECODE` env var stripped to allow nested invocation
- **Timeout:** 10 minutes

### Output Structure

```markdown
# Meeting Protocol - [Title]
## Summary
## Participants
## Topics Discussed
## Decisions
## Tasks (table)
## Open Questions

---

## Full Transcript
[appended automatically]
```

---

## Data Flow

### Observable State Propagation

```
AppSettings (UserDefaults)
  → WatchLoop (@Observable: state, detail, currentMeeting, lastError)
  → PipelineQueue (@Observable: jobs, isProcessing, pendingSpeakerNaming)
    → MeetingTranscriberApp (computed: currentStatus, currentStateLabel, currentStateIcon)
      → MenuBarView (receives status + callbacks + pipeline queue)
      → SettingsView (receives @Bindable settings)
      → SpeakerNamingView (receives pendingSpeakerNaming data)
```

### File Locations

| Content | Path |
|---------|------|
| Recordings | `~/Library/Application Support/MeetingTranscriber/recordings/` |
| Protocols | `~/Library/Application Support/MeetingTranscriber/protocols/` |
| IPC | `~/.meeting-transcriber/` |
| Speaker DB | `~/Library/Application Support/MeetingTranscriber/speakers.json` |
| Pipeline logs | `~/.meeting-transcriber/pipeline_queue.json`, `pipeline_log.jsonl` |
| AudioTapLib | Linked as SPM library (no separate binary) |

---

## Testing Hooks

| Component | Injection Point |
|-----------|----------------|
| MeetingDetector | `windowListProvider` closure (mock window list) |
| MuteDetector | `muteStateProvider` closure |
| DiarizationProvider | `diarizationFactory` closure in PipelineQueue |
| ProtocolGenerating | `protocolGenerator` protocol in PipelineQueue |
| RecordingProvider | `recorderFactory` closure in WatchLoop |
| ProtocolGenerator | `claudeBin` parameter |

---

## Permissions

| Permission | Required For | Notes |
|------------|-------------|-------|
| Screen Recording | Meeting detection (window titles) | CGWindowListCopyWindowInfo |
| Microphone | Mic recording | AVAudioEngine |
| Accessibility | Mute detection, participant reading | Teams AX tree |
| None | App audio capture | CATapDescription (purple dot only) |

---

## Key Architectural Decisions

1. **@Observable over @StateObject** — Fine-grained reactivity, macOS 14+
2. **PipelineQueue decoupling** — Recording and post-processing run independently; WatchLoop enqueues jobs and resumes watching
3. **AudioTapLib as SPM library** — Direct in-process audio capture via CATapDescription (App Store compatible)
4. **Dual-source recording** — Enables speaker separation without diarization (app=Remote, mic=Me)
5. **Graceful degradation** — Diarization optional, mute detection optional, continues on partial failure
6. **Pre-loaded model** — FluidAudio Parakeet loaded at app launch, prevents delay on first meeting
7. **5s cooldown** — Prevents re-detecting same meeting after handling
8. **FluidAudio on-device diarization** — Replaces Python pyannote subprocess, no external dependencies
9. **Dual-track diarization** — App and mic tracks diarized separately, avoiding echo/cross-talk interference
