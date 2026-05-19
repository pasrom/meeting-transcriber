# Meeting Transcriber — macOS Architecture

## Overview

Native SwiftUI menu bar application that orchestrates meeting detection, recording, transcription, diarization, and protocol generation. Runs a background watch loop (`WatchLoop`) polling for active meetings and implementing a complete end-to-end pipeline.

**Key pattern:** Observable state models (`@Observable`) with PipelineQueue for decoupled post-processing.

---

## Pipeline

```
                ┌──────────────────────────────────────────────────┐
                │           MeetingTranscriberApp (@main)          │
                │   SwiftUI: MenuBarExtra + Settings + Naming      │
                └──────────────────────────┬───────────────────────┘
                                           │ owns
                ┌──────────────────────────▼───────────────────────┐
                │            AppState (@Observable @MainActor)     │
                │   watchLoop, pipelineQueue, settings, engines    │
                └────────┬─────────────────────────────────┬───────┘
                         │                                 │ optional
                         │                                 │ (#if !APPSTORE
                         │                                 │  + env flag)
                         │                                 ▼
                         │                  ┌──────────────────────────┐
                         │                  │  DebugRPCServer          │
                         │                  │  127.0.0.1:9876          │
                         │                  │  /state /healthz         │
                         │                  │  /screenshot             │
                         │                  │  /action/openSettings    │
                         │                  │  /action/closeSettings   │
                         │                  │  Bearer-token + Origin   │
                         │                  │  reject. Driven by mt-cli│
                         │                  └──────────────────────────┘
                         │
                         ▼
                ┌─────────────────────────────────────────────────┐
                │           WatchLoop (@MainActor)                │
                │   idle → watching → recording → watching        │
                └────┬───────────────┬────────────────────┬───────┘
                     │ polls         │ starts/stops       │ enqueues
                     ▼               ▼                    ▼
        ┌─────────────────────┐  ┌────────────────┐  ┌────────────────────┐
        │ MeetingDetecting    │  │ DualSource-    │  │   PipelineQueue    │
        │  • MeetingDetector  │  │   Recorder     │  │   (@MainActor)     │
        │    (CGWindowList +  │  │                │  │                    │
        │     regex)          │  │  AudioTapLib   │  │  Sequential job    │
        │  • PowerAssertion-  │  │  (CATap +      │  │  processing →      │
        │    Detector (IOKit, │  │   AVAudioEng.) │  │  see breakdown     │
        │    sandbox-safe)    │  │  + AudioMixer  │  │  below             │
        └─────────────────────┘  └────────────────┘  └─────────┬──────────┘
                                                               │
        PipelineQueue per-job processing:                      │
        ┌──────────────────────────────────────────────────────▼─────────┐
        │ 1. Resample to 16 kHz mono (AudioMixer; AVAsset / ffmpeg fb)   │
        │ 2. (opt) FluidVAD silence-trim + timeline remap                │
        │ 3. Transcribe via active engine                                │
        │      └─ TranscribingEngine: WhisperKit | Parakeet | Qwen3      │
        │         (dual-source: each track separately, then merge)       │
        │ 4. (opt) Diarize via FluidDiarizer                             │
        │      └─ Mode: .offlineDiarizer | .sortformer                   │
        │      └─ Dual-source: app + mic diarized separately,            │
        │         IDs prefixed R_ (remote) / M_ (mic), then merged       │
        │ 5. SpeakerMatcher: cosine match against speakers.json          │
        │      (centroid + recent-FIFO, threshold 0.40, margin 0.10)     │
        │ 6. Speaker naming UI (suspended via CheckedContinuation)       │
        │ 7. Assign speakers to transcript by temporal overlap           │
        │ 8. Save transcript (.txt)                                      │
        │ 9. Protocol generation                                         │
        │      └─ ProtocolProvider: .claudeCLI | .openAICompatible | .none│
        │ 10. Save protocol (.md, transcript appended)                   │
        └────────────────────────────────────────────────────────────────┘
```

State writes to `AppPaths.dataDir`; IPC + queue snapshots to `ipcDir`.

---

## Source Files

### App Entry & UI

| File | Role |
|------|------|
| `MeetingTranscriberApp.swift` | `@main` UI shell — SwiftUI scenes, windows, NSOpenPanel, NSWorkspace. Observes `.showSettings` / `.closeSettings` / `.showSpeakerNaming` notifications for RPC- and pipeline-driven scene control |
| `AppState.swift` | `@Observable @MainActor` ViewModel — business state, badge logic, pipeline wiring |
| `MenuBarView.swift` | Menu bar dropdown (state, actions, meeting info) |
| `SettingsView.swift` | Settings window — `TabView` shell hosting six topic-grouped sub-views in `Sources/Settings/` |
| `Settings/GeneralSettingsView.swift` | Apps to Watch · Detection (Poll Interval, Grace Period) · Updates |
| `Settings/AudioSettingsView.swift` | Microphone device · VAD (enabled + threshold) |
| `Settings/TranscriptionSettingsView.swift` | ASR engine picker · engine-specific options · model status |
| `Settings/SpeakersSettingsView.swift` | Diarization · Mic Speaker Name · Known Voices · Recognition Stats |
| `Settings/OutputSettingsView.swift` | LLM provider · protocol language · output folder · custom prompt |
| `Settings/AdvancedSettingsView.swift` | Permissions · Diagnostics · About |
| `SpeakerNamingView.swift` | Speaker naming dialog after diarization |
| `KnownVoicesView.swift` | Manage persisted speaker DB (rename, delete, merge) — embedded in `SpeakersSettingsView` |
| `RecognitionStatsView.swift` | Recognition stats display — aggregate counts from `recognition_log.jsonl` |
| `VoiceEnrollmentView.swift` | Voice enrollment sheet — seeds `speakers.json` from an existing audio file |
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
| `SpeakerMatcher+Logging.swift` | Forensic match-decision logging (pseudonymized speaker names via `String.pseudonymized`) |
| `StoredSpeaker.swift` | Codable speaker DB entry model (centroid + FIFO embeddings + metadata) |
| `DiarizationProcess.swift` | Diarization result types, DiarizationProvider protocol, speaker assignment (standard + dual-track) |
| `ProtocolGenerator.swift` | Shared protocol utilities: `ProtocolGenerating` protocol, prompts, file I/O, `ProtocolError` |
| `ClaudeCLIProtocolGenerator.swift` | Claude CLI subprocess protocol generation (`#if !APPSTORE`) |
| `OpenAIProtocolGenerator.swift` | OpenAI-compatible API protocol generation (Ollama, LM Studio, etc.) |
| `RecordingSidecar.swift` | Metadata sidecar written next to recordings in record-only mode |

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
| `RecognitionStats.swift` | Recognition event model + `recognition_log.jsonl` reader/writer — backs `RecognitionStatsView` |
| `Permissions.swift` | Mic/accessibility permissions, project root detection |
| `PermissionRow.swift` | Permission status row UI component (icon, detail, help popover) |
| `PermissionHealthCheck.swift` | TCC verdict + live probe → `PermissionStatus`; drives exclamation badge overlay |
| `ParticipantReader.swift` | Teams participant extraction via Accessibility API |
| `DebugRPCServer.swift` | Embedded HTTP RPC server for shell-driven inspection. `#if !APPSTORE`, opt-in via `MEETINGTRANSCRIBER_DEBUG_RPC=1`. Bearer-token + Origin reject; binds 127.0.0.1 only |
| `AppState+RPC.swift` | Builds `RPCStateSnapshot` from live `AppState` for the `/state` endpoint (`#if !APPSTORE`) |
| `RPCStateSnapshot.swift` | JSON-serializable RPC state snapshot type (`#if !APPSTORE`) |
| `Bundle+AppVersion.swift` | Bundle extension: `appVersion` + `gitCommitHash` from `Info.plist` |
| `DiagnosticExporter.swift` | Reads log entries and writes shareable `.log` file (Settings → Advanced → Export Diagnostics) |
| `PersistentDiagnosticLog.swift` | Persistent `log stream` subprocess with sliding-window restart policy for long-term log retention |
| `String+LogRedaction.swift` | String extensions: `.pseudonymized` (SHA-256 4-hex prefix) and `.redactedName` for log privacy |

### Companion CLIs

| Path | Role |
|------|------|
| `tools/mt-cli/` | Thin Swift client for `DebugRPCServer`. Subcommands: `state`, `healthz`, `screenshot`, `open-settings`, `close-settings`. Reads token from `~/Library/Application Support/MeetingTranscriber/.rpc-token`. Skill doc at `tools/mt-cli/skill.md`. |
| `tools/whisperkit-cli/` | WhisperKit transcription CLI (used by `scripts/build_whisperkit.sh`) |
| `tools/meeting-simulator/` | Test fixture: spawns a fake meeting window for E2E detection tests |

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

### Menu Bar Icon Animations

`BadgeKind.compute(watchState:queueState:permissionUnhealthy:updateAvailable:)` is the pure function that maps the combined `WatchLoop` + `PipelineQueue` state into one of `BadgeKind.inactive | .recording | .transcribing | .diarizing | .processing | .userAction | .done | .error | .updateAvailable`. `MenuBarIcon.image(badge:permissionOverlay:recordOnlyOverlay:)` then renders the matching animation frame.

| State | GIF | Triggered by | Code path |
|-------|-----|--------------|-----------|
| **Idle** | <img src="menu-bar-idle.gif" width="60"> | `WatchLoop.state == .idle / .watching` and `PipelineQueue` empty | `BadgeKind.inactive` |
| **Recording** | <img src="menu-bar-recording.gif" width="60"> | `WatchLoop.state == .recording` (waveform bars bounce) | `BadgeKind.recording` |
| **Transcribing** | <img src="menu-bar-transcribing.gif" width="60"> | `PipelineJob.state == .transcribing / .recordingDone` (bars morph into text glyphs) | `BadgeKind.transcribing` |
| **Diarizing** | <img src="menu-bar-diarizing.gif" width="60"> | `PipelineJob.state == .diarizing` (bars split into colored speaker groups) | `BadgeKind.diarizing` |
| **Protocol** | <img src="menu-bar-protocol.gif" width="60"> | `PipelineJob.state == .generatingProtocol` (lines appear sequentially) | `BadgeKind.processing` |

The icon is rendered as a SwiftUI `Image` template (auto-tinted by AppKit for light/dark mode) **unless** an overlay applies — overlays force non-template rendering to keep the colored badge intact.

### Permission problem badge

<p>
<img src="menu-bar-permission.gif" width="80" alt="Permission problem badge">
</p>

A red circle with a white "!" is composited in the bottom-right corner by `MenuBarIcon.drawExclamationBadge` whenever `PermissionHealthCheck` reports any of Microphone / Screen Recording / Accessibility as `.denied` or `.broken`. The overlay sits **on top of whatever primary state animation** is currently active — the user still sees what the app is doing while being told something is wrong. See "Permission health check + badge overlay" below for the full health-check semantics.

### Record-only mode badge

<p>
<img src="menu-bar-record-only.gif" width="80" alt="Record-only mode">
</p>

A persistent small red dot in the bottom-right corner indicates that **Record-only mode** is enabled (`AppSettings.recordOnly == true`). In this mode `WatchLoop.enqueueRecording()` moves dual-source WAVs into `<outputDir>/recordings/` together with a `<basename>_meta.json` `RecordingSidecar` and skips the entire post-processing pipeline (VAD, transcription, diarization, protocol). Intended for fleet topologies where macOS clients capture and a separate machine (e.g. a Linux GPU host via Syncthing) processes the audio.

Like the permission badge, the dot is rendered as a persistent overlay on top of whatever primary animation is currently active — so the mode is always clearly indicated whether the app is idle, recording, or running anything else. **Precedence:** when both apply, the red exclamation (permission badge) wins, because a permission problem actually breaks recording while record-only is a deliberate user choice.

### Per-channel asymmetric-silence indicator

When one capture channel goes silent while the other is still carrying audio for longer than the configured debounce window, the waveform bars in the menu bar are tinted **red** to surface the half-broken capture at a glance. `MenuBarIcon.image(..., micSilentOverlay:appSilentOverlay:)` paints the **top half** red when the mic channel is the silent one and the **bottom half** red when the app-audio channel is the silent one. When both apply, both halves are red (effectively all-red bars). Like the permission badge, this overlay forces non-template rendering so the red stays red in dark mode.

The flags driving this overlay (`AppState.micSilentActive` / `AppState.appSilentActive`) are flipped by a ~10 Hz polling task that reads `WatchLoop.activeRecorder?.{mic,app}LevelDBFS` and feeds the values into a pure `ChannelHealthMonitor` state machine. The monitor uses two dBFS thresholds — `silenceThresholdDBFS` (-60) and `speechThresholdDBFS` (-50) — with hysteresis: an episode only starts when one channel is below silence *and* the other is above speech, and only resolves when the supposedly-silent side crosses back above the speech threshold. Transient dips into the dead zone between the thresholds (natural pauses between syllables) keep the debounce timer running rather than resetting it.

Configurable in **Settings → Audio → Per-Channel Indicator**: master toggle (default on) and threshold slider (30–300 s, default 90 s). A `Capture Channel Silent` notification fires once per episode at the same moment the menu-bar tint kicks in.

**Precedence ordering** (highest wins, composes over the others underneath):

1. Permission badge (red exclamation) — actually breaks recording
2. Channel-silent tint (red waveform halves) — degraded recording
3. Record-only dot (persistent red dot) — user-chosen mode
4. Primary state animation (idle / recording / transcribing / diarizing / protocol)

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

`SpeakerMatcher` matches diarization speaker embeddings against a persistent speaker database (`speakers.json`) using cosine similarity (threshold: 0.40, confidence margin: 0.10). Stores a running-mean centroid (primary match anchor) plus a recent-samples FIFO (max 3, fallback when centroid match is borderline). Quality filter: embeddings from segments shorter than 3 s are excluded from the centroid but kept as fallback samples. Speakers are ranked by recency and use count in the naming UI. Enables recognition of returning speakers across meetings.

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
| DebugRPCServer | Out-of-process inspection via HTTP. Endpoints: `GET /state /healthz /screenshot`, `POST /action/openSettings /action/closeSettings`. `#if !APPSTORE` + env-gated. `boundPort` exposes OS-assigned port for in-process integration tests. `tools/mt-cli/` is the matching CLI. `scripts/test_rpc.sh` is a live smoketest (build + launch + drive + assert). |

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

## Settings UI

`SettingsView` is a thin `TabView` shell. Each tab is a self-contained `View` in `Sources/Settings/` owning only the bindings it needs and its own local `@State`. The settings window is resizable (`minWidth: 620, idealWidth: 720, maxWidth: 900`).

| Tab | Sections | Bindings | Local state |
|---|---|---|---|
| **General** | Apps to Watch · Detection · Updates | `settings`, `updateChecker?` | — |
| **Audio** | Microphone · VAD | `settings` | `audioDevices` |
| **Transcription** | Engine + per-engine options + status | `settings`, three engines | — |
| **Speakers** | Diarization · Speaker Identity · Known Voices · Recognition Stats | `settings`, `recognitionStatsLog`, `enrollmentDiarizerFactory` | `showKnownVoices` |
| **Output** | LLM Provider · Protocol Language · Output Folder · Prompt | `settings` | `claudeBinaries` (#if !APPSTORE), connection-test state, `availableModels`, `hasCustomPrompt` |
| **Advanced** | Permissions · Diagnostics · About | — | `micPermission`, `screenRecordingOK`, `accessibilityOK` |

**Conditional rendering rules:**
- `noMic` hides the mic-device picker (Audio) and the Speaker Identity section (Speakers)
- `diarize` hides the diarizer-mode picker and Expected Speakers stepper
- `vadEnabled` hides the VAD threshold slider
- `transcriptionEngine` switches between WhisperKit / Parakeet / Qwen3 option panels
- `protocolProvider` switches between Claude CLI / OpenAI-compatible / None panels
- `#if APPSTORE` removes the Claude CLI provider option entirely
- `updateChecker == nil` hides the entire Updates section

**Cross-cutting concerns owned by sub-views:**
- `OutputSettingsView` owns OpenAI-endpoint connection testing (`testConnection()`) and custom-prompt I/O (`openCustomPrompt`, `importCustomPrompt`, reset confirmation)
- `AdvancedSettingsView` owns permission live-probing (`refreshPermissions()`) and version/build/ffmpeg status

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
10. **Embedded debug RPC** — In-process HTTP server (`DebugRPCServer`) exposes state + screenshot + scene actions for shell-driven inspection and integration tests. Off by default, opt-in via `MEETINGTRANSCRIBER_DEBUG_RPC=1`, excluded from App Store builds via `#if !APPSTORE`. Action endpoints route through existing `Notification.Name` observers in `MeetingTranscriberApp`, so RPC-driven flows mirror real menu-bar paths.
11. **No expensive work in SwiftUI hot paths** — view bodies, computed properties read by the body, and per-render closures must not call disk I/O, JSON decode, factory constructors, regex compilation, or other non-trivial work. SwiftUI re-renders on every `@State`/`@Observable` change and fans out aggressively, so what looks cheap once becomes a CPU pin fast. Push heavy values up: store as `@State`, inject as a stored property, or surface via an `@Observable` model. Caches that mirror the underlying source (e.g. `PipelineQueue.knownSpeakerNames` mirroring the speakers DB) must wire invalidation from every mutation site in the same PR — see issue #155 → PR #158 → PR #159 for the cautionary tale.
