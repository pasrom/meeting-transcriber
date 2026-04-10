# Meeting Transcriber — macOS Architecture

## Overview

Native SwiftUI menu bar application that orchestrates meeting detection, recording, transcription, diarization, and protocol generation. Runs a background watch loop (`WatchLoop`) polling for active meetings and implementing a complete end-to-end pipeline.

**Key pattern:** Observable state models (`@Observable`) with PipelineQueue for decoupled post-processing.

---

## Pipeline

```
Meeting Window Detected (CGWindowListCopyWindowInfo)
  → DualSourceRecorder (AudioTapLib + mic, records at 16kHz)
    → [WhisperKit | Parakeet | Qwen3] (CoreML/ANE transcription)
      → [FluidDiarizer (CoreML/ANE speaker diarization)]
        → ProtocolGenerator (Claude CLI / OpenAI-compatible API)
          → Markdown protocol + transcript
```

---

## Source Files

### App Entry & UI

| File | Role |
|------|------|
| `MeetingTranscriberApp.swift` | `@main` UI shell — SwiftUI scenes, windows, NSOpenPanel, NSWorkspace |
| `AppState.swift` | `@Observable @MainActor` ViewModel — business state, badge logic, pipeline wiring |
| `MenuBarView.swift` | Menu bar dropdown (state, actions, meeting info) |
| `SettingsView.swift` | Settings window (apps, recording, transcription, diarization) |
| `SpeakerNamingView.swift` | Speaker naming dialog after diarization |
| `AppSettings.swift` | `@Observable` settings persisted to UserDefaults |

### Core Pipeline

| File | Role |
|------|------|
| `WatchLoop.swift` | Main orchestrator: detect → record → enqueue PipelineJob |
| `MeetingDetecting.swift` | `MeetingDetecting` protocol + `DetectedMeeting` model |
| `MeetingDetector.swift` | Window title polling, pattern matching, confirmation counting, cooldown |
| `PowerAssertionDetector.swift` | IOKit power assertion–based meeting detection (sandbox-safe) |
| `MeetingPatterns.swift` | Regex patterns for Teams, Zoom, Webex |
| `DualSourceRecorder.swift` | Orchestrates AudioTapLib capture + mic, mixes tracks |
| `TranscribingEngine.swift` | `TranscribingEngine` protocol + `mergeDualSourceSegments` default impl |
| `WhisperKitEngine.swift` | WhisperKit transcription engine (99+ languages, ~1 GB model) |
| `ParakeetEngine.swift` | NVIDIA Parakeet TDT v3 via FluidAudio (25 EU languages, ~50 MB, ~10× faster) |
| `Qwen3AsrEngine.swift` | Qwen3-ASR 0.6B via FluidAudio (30 languages, ~1.75 GB, macOS 15+) |
| `PipelineQueue.swift` | Decouples recording from post-processing, sequential job pipeline |
| `PipelineJob.swift` | Pipeline job model (waiting → transcribing → diarizing → generatingProtocol → done) |
| `FluidDiarizer.swift` | On-device speaker diarization via FluidAudio CoreML/ANE |
| `SpeakerMatcher.swift` | Speaker embedding DB + cosine similarity matching |
| `DiarizationProcess.swift` | Diarization result types, DiarizationProvider protocol, speaker assignment (standard + dual-track) |
| `ProtocolGenerator.swift` | Shared protocol utilities: `ProtocolGenerating` protocol, prompts, file I/O, `ProtocolError` |
| `ClaudeCLIProtocolGenerator.swift` | Claude CLI subprocess protocol generation (`#if !APPSTORE`) |
| `OpenAIProtocolGenerator.swift` | OpenAI-compatible API protocol generation (Ollama, LM Studio, etc.) |

### Audio Processing

| File | Role |
|------|------|
| `AudioMixer.swift` | Resampling, mixing, echo suppression, mute masking, WAV I/O |
| `AudioConstants.swift` | Shared audio pipeline constants (target sample rate) |
| `MicRecorder.swift` | Microphone recording via AVAudioEngine |
| `FluidVAD.swift` | VAD preprocessing via FluidAudio Silero v6 — silence trimming + `VadSegmentMap` timeline remapping |
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
| `PermissionHealthCheck.swift` | `PermissionStatus`/`PermissionProblem` — functional health probes for all three TCC permissions (denied vs. broken detection) |
| `PermissionRow.swift` | Permission status row UI component (icon, detail, help popover) |
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
├─ Output: Interleaved float32 (mono or stereo) → FileHandle (raw PCM)
├─ Mic: AVAudioEngine → mono WAV file (MicCaptureHandler)
└─ Metadata: micDelay, actualSampleRate, actualChannels via AudioCaptureResult
```

**Key:** CATapDescription requires NO Screen Recording permission (purple dot indicator only). Handles output device changes by recreating tap automatically.

### Processing (DualSourceRecorder.stop())

```
Raw float32 (mono or stereo, actual channel count from AudioCaptureResult) → mono
  → Resample to 16kHz
  → Save app.wav (16kHz mono)
  → Load mic.wav (already 16kHz from MicCaptureHandler)
  → Apply mute mask (zero mic during muted periods)
  → Echo suppression (RMS-based gate, 20ms windows)
  → Delay alignment (prepend zeros by MIC_DELAY)
  → Mix (average tracks)
  → Save mix.wav (16kHz mono)
```

All recordings are normalized to 16kHz at capture time — no resampling needed in the pipeline.

---

## Transcription

### Engine Selection

`TranscribingEngine` protocol abstracts ASR backends. `AppSettings.transcriptionEngine` selects the active engine.

| | WhisperKit | Parakeet TDT v3 | Qwen3-ASR |
|---|---|---|---|
| **Languages** | 99+ | 25 European | 30 |
| **Model size** | ~800 MB–1.5 GB | ~50 MB | ~1.75 GB |
| **Speed (M4 Pro)** | ~10–20× RTF | ~110× RTF | TBD |
| **Language selection** | Manual or auto-detect | Auto-detect only | Manual or auto-detect |
| **Timestamps** | Per-segment | Per-token | None (single segment) |
| **macOS** | 14+ | 14+ | 15+ |
| **Hallucinations** | Can occur | Minimal | Minimal |

### WhisperKit Engine

- **Model:** `openai_whisper-large-v3-v20240930_turbo` (CoreML/ANE)
- **Pre-loading:** Model downloaded and loaded at app launch (when selected)
- **Lazy fallback:** `ensureModel()` loads on-demand if not ready

### Parakeet Engine

- **Model:** NVIDIA Parakeet TDT v3 via FluidAudio (CoreML/ANE)
- **Pre-loading:** Model downloaded and loaded at app launch (when selected)
- **Token grouping:** `groupTokensIntoSegments` groups per-token timings into sentence-level segments (split on `. ! ?` or 20 tokens)

### Qwen3-ASR Engine

- **Model:** Qwen3-ASR 0.6B via FluidAudio `Qwen3AsrManager` (CoreML/ANE, macOS 15+)
- **Pre-loading:** Model downloaded and loaded at app launch (when selected)
- **Language:** 30 languages via `Qwen3AsrConfig.Language` enum, selectable in Settings. `nil` = auto-detect.
- **No timestamps:** Returns plain text — emits single `TimestampedSegment` spanning full audio duration
- **Chunking:** Audio split into <=30s windows (`Qwen3AsrConfig.maxAudioSeconds`), results concatenated
- **Availability:** `@available(macOS 15, *)` — type-erased via `AnyObject?` in AppState for macOS <15 compatibility

### Modes

1. **Single source:** `transcribeSegments(audioPath:)` → `[TimestampedSegment]` with start/end/text
2. **Dual source:** `transcribeSegments(appAudio:)` + `transcribeSegments(micAudio:)` → `mergeDualSourceSegments(appSegments:micSegments:)` → `[TimestampedSegment]` merged by timestamp
   - App segments labeled "Remote"
   - Mic segments labeled with user's mic name (default "Me")
   - `mergeDualSourceSegments` is a protocol extension on `TranscribingEngine` — shared by all engines

### Post-processing (WhisperKit only)

- **Token stripping:** Regex `<\|[^|]*\|>` removes `<|startoftranscript|>`, `<|en|>`, etc.
- **Hallucination filtering:** Skip consecutive identical segments

---

## Diarization

### FluidDiarizer (On-device)

On-device speaker diarization using FluidAudio (CoreML/ANE). No HuggingFace token or Python subprocess needed. Models downloaded automatically on first run (~50 MB).

Two modes selected via `AppSettings.diarizerMode`:
- **`.offlineDiarizer`** (default) — `OfflineDiarizerManager`, standard speaker segmentation
- **`.sortformer`** — `SortformerDiarizer`, overlap-aware diarization (handles simultaneous speech)

Flow: `FluidDiarizer.run(audioPath, numSpeakers)` → selected diarizer → `DiarizationResult` with segments, speaking times, and speaker embeddings.

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

### Provider Selection

`AppSettings.protocolProvider` selects the active provider:
- **`.claudeCLI`** — Claude CLI subprocess (`#if !APPSTORE`)
- **`.openAICompatible`** — Any OpenAI-compatible HTTP API (Ollama, LM Studio, llama.cpp, etc.)
- **`.none`** — Skip LLM generation; save transcript only

`AppSettings.protocolLanguage` (default `"German"`) is substituted into the prompt as `{LANGUAGE}`.

### Claude CLI Invocation

```bash
/usr/bin/env claude -p - --output-format stream-json --verbose --model sonnet
```

- **Input:** Protocol prompt (with language substituted) + transcript piped to stdin
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
    → AppState (computed: currentBadge via BadgeKind.compute(), currentStatus, currentStateLabel)
      → MeetingTranscriberApp (reads appState.*, passes to views)
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
| PowerAssertionDetector | `assertionProvider` + `windowListProvider` closures |
| DiarizationProvider | `diarizationFactory` closure in PipelineQueue |
| ProtocolGenerating | `protocolGenerator` protocol in PipelineQueue |
| RecordingProvider | `recorderFactory` closure in WatchLoop |
| ProtocolGenerator | `claudeBin` parameter |
| AppNotifying | `notifier` parameter in `AppState.init` (`SilentNotifier` default, `RecordingNotifier` in tests) |
| BadgeKind.compute | Pure static function — call directly with any input combination, no WatchLoop needed |

---

## Permissions

| Permission | Required For | Notes |
|------------|-------------|-------|
| Screen Recording | Meeting detection (window titles) | CGWindowListCopyWindowInfo |
| Microphone | Mic recording | AVAudioEngine |
| Accessibility | Mute detection, participant reading | Teams AX tree |
| None | App audio capture | CATapDescription (purple dot only) |

### Permission health check + badge overlay

`PermissionHealthCheck` verifies each of the three TCC permissions by combining the system verdict with a live probe (e.g. `CGWindowListCopyWindowInfo` returning non-empty window titles for Screen Recording). Each permission resolves to `PermissionStatus.healthy | .denied | .broken | .notDetermined` — `.broken` means "TCC says allowed but the probe disagrees," which happens when macOS hasn't actually wired the permission through and the user needs to toggle it off and on in System Settings.

`WatchLoop` runs the check on startup and `AppState` re-runs it on app activation. When the result is unhealthy:

1. `MeetingTranscriberApp` passes `permissionOverlay: true` to `MenuBarIcon.image(...)`, which composites a red circle with a white "!" in the bottom-right corner over the current badge (`MenuBarIcon.drawExclamationBadge`). This bypasses the cached template icons and renders a non-template image because the overlay must stay red in both light and dark mode.
2. `BadgeKind.compute(...)` returns `.error` when idle-with-problem, so the icon also reflects the problem state when no job is active.
3. A notification is posted via `NotificationManager` with the list of affected permissions (deduplicated — only re-posted when the problem set actually changes).

The overlay lives over the *currently active* animation (idle, recording, transcribing, …) so the user still sees what the app is doing and is simultaneously told "one of the permissions is wrong."

<p>
<img src="menu-bar-permission.gif" width="80" alt="Permission problem badge">
</p>

---

## Key Architectural Decisions

1. **@Observable over @StateObject** — Fine-grained reactivity, macOS 14+
2. **PipelineQueue decoupling** — Recording and post-processing run independently; WatchLoop enqueues jobs and resumes watching
3. **AudioTapLib as SPM library** — Direct in-process audio capture via CATapDescription (App Store compatible)
4. **Dual-source recording** — Enables speaker separation without diarization (app=Remote, mic=Me)
5. **Graceful degradation** — Diarization optional, mute detection optional, continues on partial failure
6. **Pre-loaded model** — Selected engine (WhisperKit, Parakeet, or Qwen3) loaded at app launch, prevents delay on first meeting
7. **5s cooldown** — Prevents re-detecting same meeting after handling
8. **FluidAudio on-device diarization** — Replaces Python pyannote subprocess, no external dependencies
9. **Dual-track diarization** — App and mic tracks diarized separately, avoiding echo/cross-talk interference
