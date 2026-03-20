> **Note (2026-03-18):** This document predates the migration from WhisperKit to FluidAudio Parakeet TDT for transcription. All references to `WhisperKitEngine` now correspond to `FluidTranscriptionEngine`. See [architecture-macos.md](../architecture-macos.md) for the current architecture.

# MeetingTranscriber: Native Swift Pipeline Architecture

## 1. Overview

MeetingTranscriber is a macOS menu bar application that automatically detects active video conference meetings (Teams, Zoom, Webex), records both application audio and microphone input, transcribes the audio using on-device CoreML inference (WhisperKit), optionally diarizes speakers using on-device neural embeddings (FluidAudio), and generates structured meeting protocols in German via the Claude CLI. The entire pipeline runs natively in Swift with no Python dependencies at runtime. The app uses SwiftUI with `MenuBarExtra` for its UI, Swift concurrency (`async`/`await`) for orchestration, and a decoupled pipeline queue that allows recording to continue while previous meetings are still being processed.

## 2. System Diagram

```
                         ┌──────────────────────────────────────────────────┐
                         │              MeetingTranscriberApp               │
                         │  @main, MenuBarExtra, Window scenes              │
                         └──────────────────┬───────────────────────────────┘
                                            │ owns
                         ┌──────────────────▼───────────────────────────────┐
                         │              WatchLoop (@MainActor)              │
                         │  State: idle → watching → recording → watching   │
                         └───────┬──────────┬───────────────┬───────────────┘
                                 │          │               │
                    polls every   │          │ starts        │ enqueues
                    N seconds     │          │               │ PipelineJob
                                 ▼          ▼               ▼
                  ┌──────────────────┐ ┌──────────────┐ ┌──────────────────────┐
                  │  MeetingDetector │ │DualSource-   │ │   PipelineQueue      │
                  │                  │ │  Recorder    │ │   (@MainActor)       │
                  │  CGWindowList    │ │              │ │                      │
                  │  + regex match   │ │  audiotap    │ │  Sequential jobs:    │
                  │  + confirmation  │ │  + MicRec    │ │  ┌─────────────────┐ │
                  └──────────────────┘ │  + MuteDet   │ │  │  Resample       │ │
                                       │  + AudioMix  │ │  │  (48k→16k)     │ │
                                       └──────────────┘ │  ├─────────────────┤ │
                                                        │  │  Transcribe     │ │
                                                        │  │  (WhisperKit)   │ │
              ┌────────────────────────┐                │  ├─────────────────┤ │
              │  ParticipantReader     │                │  │  Diarize        │ │
              │  (AX API, Teams only)  │                │  │  (FluidAudio)   │ │
              └────────────────────────┘                │  ├─────────────────┤ │
                                                        │  │  Speaker Match  │ │
                                                        │  │  (cosine sim)   │ │
              ┌────────────────────────┐                │  ├─────────────────┤ │
              │  SpeakerNamingView     │◄───────────────│  │  Name Speakers  │ │
              │  (SwiftUI Window)      │────mapping────▶│  │  (UI prompt)    │ │
              └────────────────────────┘                │  ├─────────────────┤ │
                                                        │  │  Save Transcript│ │
                                                        │  ├─────────────────┤ │
                                                        │  │  Protocol Gen   │ │
                                                        │  │  (Claude CLI)   │ │
                                                        │  ├─────────────────┤ │
                                                        │  │  Save Protocol  │ │
                                                        │  └─────────────────┘ │
                                                        └──────────────────────┘

Audio Capture Detail:
  ┌──────────────┐    ┌───────────────────────┐    ┌──────────────────┐
  │ Target App   │    │ audiotap (subprocess)  │    │ DualSourceRecorder│
  │ (e.g. Teams) │───▶│ CATapDescription      │───▶│ reads stdout     │
  │              │    │ → aggregate device     │    │ float32 stereo   │
  └──────────────┘    │ → IOProc → stdout      │    │ → mono → WAV     │
                      │                         │    │                  │
                      │ --mic flag:             │    │ loads mic WAV    │
                      │ AVAudioEngine → WAV     │    │ echo suppress    │
                      │ MIC_DELAY on stderr     │    │ mute mask        │
                      └───────────────────────┘    │ delay align      │
                                                    │ mix → WAV        │
                                                    └──────────────────┘
```

## 3. Components

### 3.1 MeetingTranscriberApp

**File:** `Sources/MeetingTranscriberApp.swift`
**Responsibility:** Application entry point. Owns the SwiftUI scene graph: a `MenuBarExtra` for the dropdown UI, a `Window` for speaker naming, and a `Window` for settings. Wires together `WatchLoop`, `PipelineQueue`, `WhisperKitEngine`, and `AppSettings`. Handles auto-watch on launch (via `--auto-watch` CLI flag or `autoWatch` UserDefaults key).

**Key types:** `MeetingTranscriberApp` (struct, conforms to `App`)
**Dependencies:** `WatchLoop`, `PipelineQueue`, `WhisperKitEngine`, `AppSettings`, `NotificationManager`, `MenuBarView`, `SettingsView`, `SpeakerNamingView`
**Concurrency:** The app struct itself is on `@MainActor` implicitly (SwiftUI `App`). WhisperKit model loading is kicked off in a `.task` modifier on the menu bar label. Watch loop toggling uses `Task { }` for async permission checks before constructing the loop on `MainActor.run`.

### 3.2 WatchLoop

**File:** `Sources/WatchLoop.swift`
**Responsibility:** Orchestrates the detect-record-enqueue cycle. Polls `MeetingDetector` at a configurable interval, starts `DualSourceRecorder` when a meeting is confirmed, waits for the meeting to end (grace period + max duration), then stops recording and enqueues a `PipelineJob` to `PipelineQueue`.

**Key types:** `WatchLoop` (class, `@MainActor`, `@Observable`)
**State machine:** `idle` → `watching` → `recording` → `watching` (loops), with `error` as a transient state.
**Dependencies:** `MeetingDetector`, `RecordingProvider` (factory closure), `PipelineQueue`, `ParticipantReader`
**Concurrency:** `@MainActor`. The watch loop runs as a `Task<Void, Never>` stored in `watchTask`. Cancellation is cooperative via `Task.isCancelled` checks.

**Key methods:**
- `start()` / `stop()` — lifecycle control
- `handleMeeting(_:)` — records a single meeting session
- `waitForMeetingEnd(_:)` — polls detector until meeting window disappears for `endGracePeriod` seconds
- `cleanTitle(_:)` — strips app suffixes like " | Microsoft Teams"

### 3.3 PipelineQueue

**File:** `Sources/PipelineQueue.swift`
**Responsibility:** Decouples recording from post-processing. Accepts `PipelineJob` entries and processes them sequentially through: resample → transcribe → diarize → speaker match → speaker naming UI → save transcript → generate protocol → save protocol. This allows WatchLoop to immediately resume watching for the next meeting.

**Key types:** `PipelineQueue` (class, `@MainActor`, `@Observable`), `PipelineQueue.SpeakerNamingData` (includes `micSpeakerID` — identified mic speaker label — and `micLabel` — locked display name — for hybrid mode)
**Dependencies:** `WhisperKitEngine`, `DiarizationProvider` (factory closure), `ProtocolGenerating`, `AudioMixer`, `SpeakerMatcher`
**Concurrency:** `@MainActor`. Processing runs as a `Task<Void, Never>` in `processTask`. Speaker naming suspends via `withCheckedContinuation` — the pipeline pauses until the user confirms names in the `SpeakerNamingView` window.

**Processing pipeline in `processNext()`:**
1. Create temp working directory
2. Resample audio to 16kHz via `AudioMixer.resampleFile()` (dual-source: app + mic separately; single-source: mix only)
3. Transcribe via two `WhisperKitEngine.transcribeSegments()` calls (dual-source: app + mic separately) then `mergeDualSourceSegments()`, or one `transcribeSegments()` call (single-source). Segments are cached for reuse in diarization
4. If diarization enabled: run `FluidDiarizer` on mix_16k. In hybrid mode (dual-source + non-empty micLabel): identify mic speaker via `DiarizationProcess.identifyMicSpeaker()`, pre-fill mic speaker name, call `SpeakerMatcher.preMatchParticipants()` if participants available, prompt for unmatched names, then assign speakers via `DiarizationProcess.assignSpeakersHybrid()` (mic segments locked, app segments get diarization names). In single-source mode: standard `DiarizationProcess.assignSpeakers()` with nearest-segment fallback
5. Save transcript via `ProtocolGenerator.saveTranscript()`
6. Generate protocol via `ProtocolGenerating.generate()`
7. Save protocol (protocol markdown + appended full transcript)
8. Update job state to `.done`

**Caching:** Transcription segments are cached (`cachedSegments`) to avoid double transcription — segments from step 3 are reused in step 4 for speaker assignment.

**Logging:** Writes `pipeline_queue.json` (atomic snapshot) and `pipeline_log.jsonl` (append-only event log) to `logDir` on every state change.

### 3.4 PipelineJob

**File:** `Sources/PipelineJob.swift`
**Responsibility:** Value type representing a single pipeline job.
**Key types:** `PipelineJob` (struct, `Codable`, `Sendable`, `Identifiable`), `JobState` (enum)
**States:** `waiting` → `transcribing` → `diarizing` → `generatingProtocol` → `done` | `error`
**Fields:** `id: UUID`, `meetingTitle`, `appName`, `mixPath: URL`, `appPath: URL?`, `micPath: URL?`, `micDelay: TimeInterval`, `enqueuedAt: Date`, `state`, `error: String?`, `protocolPath: URL?`

### 3.5 DualSourceRecorder

**File:** `Sources/DualSourceRecorder.swift`
**Responsibility:** Orchestrates simultaneous app audio capture (via `audiotap` subprocess) and microphone recording (via `audiotap --mic`). On stop, converts raw float32 stdout data to mono samples, loads mic WAV, applies mute masking, echo suppression, delay alignment, and mixes both tracks into a single WAV.

**Key types:** `DualSourceRecorder` (class, `@Observable`, conforms to `RecordingProvider`), `RecordingResult`, `RecordingProvider` (protocol)

**App audio flow:**
1. Launches `audiotap` binary as a `Process` with PID, sample rate (48kHz), and channel count (2) as arguments
2. Reads interleaved float32 stereo PCM from stdout in a detached `Task`
3. On stop: terminates process, converts stereo→mono, saves as `_app.wav`, resamples to 48kHz if actual rate differs

**Mic audio flow:**
1. `audiotap --mic <path>` flag causes the subprocess to record mic via AVAudioEngine directly to a WAV file
2. On stop: loads WAV, applies mute mask from `MuteDetector` timeline, applies echo suppression, aligns by `MIC_DELAY` from stderr

**Mixing:** `AudioMixer.mixTracks()` averages the two mono tracks. Result saved as `_mix.wav`.

**Dependencies:** `AudioMixer`, `MuteDetector`, `Permissions.findProjectRoot()` (for finding audiotap binary)

### 3.6 audiotap

**File:** `tools/audiotap/Sources/main.swift`
**Responsibility:** Standalone Swift CLI that captures application audio using `CATapDescription` (macOS 14.2+, CoreAudio). Does not require Screen Recording permission — uses the "purple dot" audio capture API.

**Key types:** `AppAudioCapture` (class), `MicCaptureHandler` (class), `AudioTap` (`@main` struct)

**How it works:**
1. Translates target PID to a CoreAudio process object via `kAudioHardwarePropertyTranslatePIDToProcessObject`
2. Creates a `CATapDescription` for the target process (stereo mixdown, private, unmuted)
3. Creates an aggregate device combining the system output device + the tap
4. Installs an `AudioDeviceIOProcID` that writes raw interleaved float32 to stdout via POSIX `write()`
5. Reports `ACTUAL_RATE=<hz>` and `MIC_DELAY=<seconds>` on stderr at shutdown

**Device change handling:** Listens for `kAudioHardwarePropertyDefaultOutputDevice` changes and recreates the tap. Mic handler listens for `kAudioHardwarePropertyDefaultInputDevice` changes and restarts AVAudioEngine.

**Build:** `swift build -c release` in `tools/audiotap/`. Requires macOS 14.2+. No external dependencies.

### 3.7 AudioMixer

**File:** `Sources/AudioMixer.swift`
**Responsibility:** Audio processing utilities — mixing, echo suppression, mute masking, resampling, and WAV I/O.

**Key types:** `AudioMixer` (struct, all static methods)

**Key methods:**
- `mix(appAudioPath:micAudioPath:outputPath:...)` — full mix pipeline
- `mixTracks(_:_:)` — averages two float arrays, extends with longer track's tail
- `applyMuteMask(samples:timeline:...)` — zeros mic samples during muted periods using `MuteTransition` timeline
- `suppressEcho(appSamples:micSamples:...)` — RMS-based gate in 20ms windows; suppresses mic where app has energy. Uses 40ms lookahead + 200ms decay margins
- `resample(_:from:to:)` — linear interpolation resampling
- `resampleFile(from:to:targetRate:)` — convenience: load WAV → resample → save (default target: 16kHz)
- `loadWAVAsFloat32(url:)` — loads any WAV as mono float32 (averages channels)
- `saveWAV(samples:sampleRate:url:)` — saves float32 samples as 16-bit PCM WAV

### 3.8 WhisperKitEngine

**File:** `Sources/WhisperKitEngine.swift`
**Responsibility:** On-device speech-to-text using WhisperKit (CoreML/ANE). Manages model lifecycle (download, load, unload) and provides transcription APIs.

**Key types:** `WhisperKitEngine` (class, `@Observable`, `final`), `TimestampedSegment` (struct), `TranscriptionError` (enum)

**Model loading:**
- `loadModel()` downloads the model variant (default: `openai_whisper-large-v3-v20240930_turbo`), then initializes `WhisperKit` with the local model folder
- Deduplicates concurrent loads via `loadingTask: Task<Void, Never>?` — second caller awaits the first's task
- States: `unloaded` → `downloading` (with progress callback) → `loading` → `loaded`

**Transcription APIs:**
- `transcribe(audioPath:)` — returns formatted `[MM:SS] text` string
- `transcribeSegments(audioPath:)` — returns `[TimestampedSegment]` with start/end times. Filters hallucinations by skipping consecutive identical segments. Strips Whisper special tokens via regex
- `mergeDualSourceSegments(appSegments:micSegments:micDelay:micLabel:)` — takes pre-transcribed segments, shifts mic by delay, labels speakers ("Remote" / micLabel), merges sorted by start time. Used by PipelineQueue after transcribing both tracks separately

**Input requirement:** 16kHz mono WAV. The caller (PipelineQueue) handles resampling.

### 3.9 FluidDiarizer

**File:** `Sources/FluidDiarizer.swift`
**Responsibility:** On-device speaker diarization using FluidAudio (CoreML/ANE). No HuggingFace token or Python subprocess needed. Models are downloaded automatically on first run (~50 MB).

**Key types:** `FluidDiarizer` (class, conforms to `DiarizationProvider`)

**How it works:**
1. Creates an `OfflineDiarizerManager` with optional `numSpeakers` constraint
2. Calls `prepareModels()` (downloads CoreML models on first run)
3. Calls `process(audioPath)` to get segments with speaker IDs and optional speaker embeddings
4. Normalizes speaker IDs from FluidAudio format ("Speaker 0") to internal format ("SPEAKER_0")
5. Computes per-speaker speaking times
6. Returns `DiarizationResult` with segments, speaking times, empty autoNames, and embeddings

**Manager reuse:** Recreates the `OfflineDiarizerManager` only if `numSpeakers` changes.

### 3.10 SpeakerMatcher

**File:** `Sources/SpeakerMatcher.swift`
**Responsibility:** Matches diarization speaker embeddings against a persistent speaker database using cosine similarity. Enables the app to recognize returning speakers across meetings.

**Key types:** `SpeakerMatcher` (class), `StoredSpeaker` (struct, `Codable`)

**Key methods:**
- `match(embeddings:)` — greedy matching: for each label sorted alphabetically, finds the closest stored speaker below `threshold` (default 0.65). Returns `[label: name]` mapping; unmatched labels map to themselves
- `updateDB(mapping:embeddings:)` — updates or appends speakers in the JSON database
- `cosineDistance(_:_:)` — returns 0 (identical) to 2 (opposite)

**Participant pre-matching:**
- `preMatchParticipants(mapping:speakingTimes:participants:excludeLabels:)` → `[String: String]` — Static method. Pre-assigns participant names (e.g. from Teams roster) to unmatched speakers by descending speaking time. Only applies when unmatched remote speaker count equals unmatched participant count exactly. Excludes specified labels (e.g. mic speaker). This is a heuristic — the naming popup lets users correct mistakes.

**Migration:** `migrateIfNeeded(dbPath:)` detects old pyannote-format DB (dictionary) vs. new format (array of `StoredSpeaker`) and backs up the old file.

**Storage:** `speakers.json` at `AppPaths.speakersDB`

### 3.11 DiarizationProcess

**File:** `Sources/DiarizationProcess.swift`
**Responsibility:** Defines the diarization result types and the speaker assignment algorithm.

**Key types:** `DiarizationResult` (struct), `DiarizationResult.Segment`, `DiarizationProvider` (protocol), `DiarizationProcess` (enum with static methods)

**Speaker assignment:** `assignSpeakers(transcript:diarization:)` assigns speakers to transcript segments by maximum temporal overlap. For each `TimestampedSegment`, it finds the `DiarizationResult.Segment` with the most overlapping time and applies the auto-named speaker label. When no overlap exists, falls back to nearest diarization segment by gap distance.

**Dual-track speaker assignment methods:**
- `mergeDualTrackDiarization(appDiarization:micDiarization:)` → `DiarizationResult` — Merges two separate diarization results, prefixing speaker IDs with `R_` (remote/app) and `M_` (mic/local). Segments sorted by time.
- `assignSpeakersDualTrack(appSegments:micSegments:appDiarization:micDiarization:)` → `[TimestampedSegment]` — Assigns speakers from respective diarizations: app segments matched against app diarization, mic segments against mic diarization. Result merged sorted by start time.

**Protocol for DI:** `DiarizationProvider` is the abstraction used by `PipelineQueue`:
```swift
protocol DiarizationProvider {
    var isAvailable: Bool { get }
    func run(audioPath: URL, numSpeakers: Int?, meetingTitle: String) async throws -> DiarizationResult
}
```

### 3.12 ProtocolGenerator

**File:** `Sources/ProtocolGenerator.swift`
**Responsibility:** Generates meeting protocols by invoking the Claude CLI as a subprocess. Parses stream-json output for real-time text accumulation.

**Key types:** `ProtocolGenerator` (struct, static methods), `DefaultProtocolGenerator` (struct, conforms to `ProtocolGenerating`), `ProtocolGenerating` (protocol)

**Protocol for DI:**
```swift
protocol ProtocolGenerating {
    func generate(transcript: String, title: String, diarized: Bool, claudeBin: String) async throws -> String
}
```

**How it works:**
1. Resolves Claude CLI path — checks `~/.local/bin/`, `/usr/local/bin/`, `~/.npm-global/bin/`, `/opt/homebrew/bin/`, falls back to `/usr/bin/env`
2. Launches process with `["-p", "-", "--output-format", "stream-json", "--verbose", "--model", "sonnet"]`
3. Strips `CLAUDECODE` env var (required for nested Claude CLI invocation)
4. Writes prompt to stdin (system prompt + optional diarization note + transcript)
5. Reads `stream-json` lines from stdout: extracts text from `content_block_delta` events (streaming) and `assistant` message (final)
6. Awaits process exit via `terminationHandler` + `withCheckedContinuation` (non-blocking)
7. Timeout: 600 seconds

**File operations:** `saveTranscript()` and `saveProtocol()` write to the output directory with filenames like `20260309_1430_meeting_title.txt` / `.md`.

### 3.13 MeetingDetector

**File:** `Sources/MeetingDetector.swift`
**Responsibility:** Detects active meeting windows by polling `CGWindowListCopyWindowInfo` and matching window titles against app-specific regex patterns.

**Key types:** `MeetingDetector` (class, `@Observable`), `DetectedMeeting` (struct)

**Detection algorithm:**
1. Gets all on-screen windows via `CGWindowListCopyWindowInfo`
2. For each window, matches owner name against pattern's `ownerNames`
3. Checks minimum window size (filters out notification overlays)
4. Skips windows matching `idlePatterns` (e.g., "Chat |", "Calendar |" for Teams)
5. Matches against `meetingPatterns` (e.g., `.+ | Microsoft Teams`)
6. Counts each pattern once per poll to prevent over-counting from multiple matching windows
7. Returns `DetectedMeeting` only after `confirmationCount` (default: 2) consecutive positive detections
8. After handling a meeting, applies a 5-second cooldown per app to avoid re-detecting the same meeting

**Regex pre-compilation:** Patterns are compiled to `NSRegularExpression` in `init()` and stored in `compiledMeetingPatterns` / `compiledIdlePatterns` dictionaries.

**Testability:** `windowListProvider` is a closure (default: `CGWindowListCopyWindowInfo`) that can be replaced in tests.

### 3.14 MeetingPatterns

**File:** `Sources/MeetingPatterns.swift`
**Responsibility:** Defines `AppMeetingPattern` configurations for supported meeting apps.

**Supported apps:**
- **Microsoft Teams** — owner names: "Microsoft Teams", "Microsoft Teams (work or school)"; meeting pattern: `.+ | Microsoft Teams`; idle patterns for Chat, Activity, Calendar, etc.
- **Zoom** — owner: "zoom.us"; patterns: "Zoom Meeting", "Zoom Webinar", `*- Zoom`
- **Webex** — owners: "Webex", "Cisco Webex Meetings"; patterns: `*- Webex`, "Meeting |", `*'s Personal Room`
- **MeetingSimulator** — debug pattern for testing without a real meeting app

### 3.15 MuteDetector

**File:** `Sources/MuteDetector.swift`
**Responsibility:** Polls the Teams mute button state via the Accessibility API and records a timeline of mute/unmute transitions. The timeline is later used by `DualSourceRecorder` to zero mic samples during muted periods.

**Key types:** `MuteDetector` (class, `@Observable`), `MuteTransition` (struct, `Sendable`)

**How it works:**
1. Verifies `AXIsProcessTrusted()` — gracefully degrades if not
2. Polls every 0.5s in a `Task.detached(priority: .utility)`
3. Recursively searches the AX tree (max depth 25) for a button whose `AXDescription` starts with mute/unmute prefixes (English and German)
4. Records `MuteTransition(timestamp: systemUptime, isMuted: Bool)` on state changes

**Testability:** `muteStateProvider` closure can be injected to replace AX API calls.

### 3.16 ParticipantReader

**File:** `Sources/ParticipantReader.swift`
**Responsibility:** Reads meeting participant names from the Teams roster via the Accessibility API and writes them to `participants.json`.

**Three detection strategies (tried in order):**
1. **Known panel identifiers** — searches AX tree for elements with identifiers like "roster-list", "people-pane"
2. **List/Table containers** — finds `AXList`/`AXTable`/`AXOutline` elements with 2+ children, extracts text values from rows
3. **Window title parsing** — parses "Name1, Name2 | Microsoft Teams" format

**Filtering:** `filterParticipantNames()` removes UI labels ("mute", "camera", "share", etc.), timestamps, numbers, and "(you)" suffixes.

### 3.17 AppSettings

**File:** `Sources/AppSettings.swift`
**Responsibility:** `@Observable` settings backed by `UserDefaults`. Each property uses a `didSet` to persist changes.

**Settings categories:**
- **Apps to Watch:** `watchTeams`, `watchZoom`, `watchWebex`, `autoWatch`
- **Recording:** `pollInterval` (min 1s), `endGrace` (min 1s), `noMic`, `micDeviceUID`, `micName` (default "Me")
- **Transcription:** `whisperKitModel` (default large-v3-turbo), `diarize` (default true), `numSpeakers` (0 = auto)

### 3.18 AppPaths

**File:** `Sources/AppPaths.swift`
**Responsibility:** Centralized path constants.

**Paths:**
- `ipcDir` = `~/.meeting-transcriber/` — IPC directory (pipeline queue JSON logs)
- `dataDir` = `~/Library/Application Support/MeetingTranscriber/` — app data
- `recordingsDir` = `dataDir/recordings/` — raw audio files
- `protocolsDir` = `dataDir/protocols/` — output protocols and transcripts
- `speakersDB` = `dataDir/speakers.json` — speaker voice profiles
- `logSubsystem` = `"com.meetingtranscriber"` — os.log subsystem

### 3.19 UI Components

**MenuBarView** (`Sources/MenuBarView.swift`): Dropdown menu showing status header, meeting info, start/stop button, pipeline queue with per-job state indicators (colored dots), protocol actions, and settings/quit. Receives all actions as closures — fully stateless.

**SettingsView** (`Sources/SettingsView.swift`): Grouped form with sections for app selection, recording parameters, transcription model (with download progress), diarization toggle, permission status display, and version info. Receives `WhisperKitEngine` as a stored property (not `@State`).

**SpeakerNamingView** (`Sources/SpeakerNamingView.swift`): Pop-up window shown when diarization finds unmatched speakers. Displays each speaker's label, auto-matched name, and speaking time. Uses custom `AccessibleTextField` (NSViewRepresentable wrapping `AutomationTextField`) that properly syncs AppleScript accessibility value changes to SwiftUI bindings — standard TextField ignores programmatic AX value changes. Supports Skip (returns empty mapping) and Confirm. In hybrid mode, the mic speaker row is locked: shows a mic icon, non-editable name display (micLabel), and no text field. The `isMicSpeaker()` helper checks if a label matches `data.micSpeakerID`. Participant name suggestion buttons appear below each unlocked speaker's text field, showing unused names from the meeting roster.

### 3.20 Supporting Components

**AXHelper** (`Sources/AXHelper.swift`): Shared enum with a single `getAttribute(_:attribute:)` method wrapping `AXUIElementCopyAttributeValue`. Used by `MuteDetector` and `ParticipantReader`.

**Permissions** (`Sources/Permissions.swift`): Static methods for checking/requesting Screen Recording, Microphone, and Accessibility permissions. `findProjectRoot()` walks up from the executable to find the project root (directory containing `VERSION`).

**NotificationManager** (`Sources/NotificationManager.swift`): Singleton wrapping `UNUserNotificationCenter`. Shows banners for meeting detection, protocol ready, speaker naming prompt, and errors. Shows notifications even when app is in foreground.

**TranscriberStatus** / **TranscriberState** (`Sources/TranscriberStatus.swift`): Status models with state enum, meeting info, and labels/icons for the menu bar.

**MicRecorder** (`Sources/MicRecorder.swift`): Standalone mic recorder using AVAudioEngine (used for standalone mic recording, separate from audiotap's built-in mic capture). Supports device selection by CoreAudio UID.

### 3.21 Dual-Track Diarization

When a dual-source recording (app + mic) is available, the pipeline diarizes each track independently:

1. **Dual-source transcription** — WhisperKit transcribes app and mic tracks separately, labeling segments "Remote" and micLabel
2. **Separate diarization** — FluidAudio runs on app track (remote speakers) and mic track (local speakers) independently
3. **Merge** — `mergeDualTrackDiarization()` prefixes speaker IDs (`R_` for remote, `M_` for local), merges segments by time
4. **Speaker matching** — Merged embeddings matched against speaker DB
5. **Participant pre-matching** — If Teams participants available and unmatched count matches, assigns by speaking time
6. **Speaker naming UI** — Shows naming dialog, all rows editable with participant suggestions
7. **Dual-track assignment** — `assignSpeakersDualTrack()` matches app segments against app diarization, mic segments against mic diarization

Separate diarization avoids echo interference (mic picking up speaker output) and produces cleaner speaker clusters per track. Single-source recordings fall back to diarizing the mix with `assignSpeakers()`.

## 4. Data Flow

### 4.1 Audio Path

```
App Audio:  Target PID → audiotap (CATapDescription) → stdout (float32 stereo @ 48kHz)
                          ↓
                     DualSourceRecorder reads stdout → stereo→mono → _app.wav (48kHz)
                          ↓
Mic Audio:  audiotap --mic → AVAudioEngine → _mic.wav (native rate)
                          ↓
                     DualSourceRecorder loads _mic.wav
                          ↓
Processing: mute mask (MuteDetector timeline) → echo suppression (RMS gate)
            → delay alignment (MIC_DELAY from audiotap stderr)
            → mix (average both tracks) → _mix.wav (48kHz)
```

### 4.2 Pipeline Data Path

```
PipelineJob { mixPath, appPath?, micPath?, micDelay }
    ↓
[Resample] 48kHz WAVs → 16kHz WAVs (temp directory, via AudioMixer.resampleFile)
    ↓
[Transcribe]
  Dual-source: WhisperKit.transcribeSegments(app_16k) + transcribeSegments(mic_16k) → mergeDualSourceSegments() → [TimestampedSegment]
  Single-source: WhisperKit.transcribeSegments(mix_16k) → [TimestampedSegment] (cached)
    ↓
[Diarize] (optional)
  FluidDiarizer.run(mix_16k) → DiarizationResult { segments, speakingTimes, embeddings }
    ↓
[Speaker Match]
  SpeakerMatcher.match(embeddings) → { "SPEAKER_0": "Roman", "SPEAKER_1": "SPEAKER_1" }
    ↓
[Name Speakers] (if unmatched speakers exist)
  PipelineQueue suspends via CheckedContinuation
  SpeakerNamingView shown → user confirms mapping
  SpeakerMatcher.updateDB() persists new speaker embeddings
    ↓
[Assign Speakers]
  DiarizationProcess.assignSpeakers(transcript, diarization) → [TimestampedSegment with speaker]
  Format: "[MM:SS] SpeakerName: text"
    ↓
[Save Transcript] → {outputDir}/{date}_{slug}.txt
    ↓
[Generate Protocol]
  ProtocolGenerator.generate(transcript, title, diarized) → Claude CLI subprocess
  Prompt: system prompt + diarization note + transcript → stream-json → accumulated text
    ↓
[Save Protocol] → {outputDir}/{date}_{slug}.md
  Content: protocol markdown + "\n\n---\n\n## Full Transcript\n\n" + original transcript
```

### 4.3 Recording Files

Each recording session produces up to three files in `AppPaths.recordingsDir`:
- `{yyyyMMdd_HHmmss}_app.wav` — app audio track (48kHz mono)
- `{yyyyMMdd_HHmmss}_mic.wav` — mic audio track (native rate)
- `{yyyyMMdd_HHmmss}_mix.wav` — mixed track (48kHz mono)

## 5. Dependencies

### SPM Packages (app/MeetingTranscriber/Package.swift)

| Package | Version | Purpose |
|---------|---------|---------|
| [WhisperKit](https://github.com/argmaxinc/WhisperKit) | >= 0.9.0 | On-device speech-to-text via CoreML/ANE. Provides `WhisperKit`, `DecodingOptions`, `WhisperKitConfig`, `ModelState` |
| [FluidAudio](https://github.com/FluidInference/FluidAudio) | >= 0.12.2 | On-device speaker diarization via CoreML/ANE. Provides `OfflineDiarizerManager`, `OfflineDiarizerConfig` |
| [ViewInspector](https://github.com/nalexn/ViewInspector) | >= 0.10.0 | Test-only. Enables unit testing of SwiftUI views |

### System Frameworks

| Framework | Usage |
|-----------|-------|
| AVFoundation | Audio recording (AVAudioEngine, AVAudioFile, AVAudioPCMBuffer), device discovery |
| CoreAudio | Device enumeration, device property queries, aggregate device creation |
| CoreGraphics | `CGWindowListCopyWindowInfo` for meeting detection |
| ApplicationServices | Accessibility API (AXUIElement) for mute detection and participant reading |
| Accelerate | Available for future vDSP optimizations (not currently imported) |
| UserNotifications | macOS notification banners |

### External Tool

| Tool | Purpose |
|------|---------|
| `claude` CLI | Protocol generation. Resolved at runtime from common install paths. Invoked as a subprocess with `--output-format stream-json` |

## 6. Concurrency Model

### @MainActor Classes

The following classes are `@MainActor` and `@Observable`:
- **WatchLoop** — all state mutations and UI-visible properties
- **PipelineQueue** — job list, processing state, speaker naming data
- **MeetingDetector** — consecutive hit counters

Tests for `@MainActor` classes must also be `@MainActor`:
```swift
@MainActor
final class WatchLoopTests: XCTestCase { ... }
```

### Task Structure

```
MeetingTranscriberApp
  └─ .task { whisperKit.loadModel() }         // Model preloading
  └─ toggleWatching()
       └─ Task { ... MainActor.run { loop.start() } }
            └─ WatchLoop.watchTask              // Polling loop
                 └─ polls detector every N seconds
                 └─ handleMeeting() → recorder.start/stop
                 └─ pipelineQueue.enqueue(job)
                      └─ PipelineQueue.processTask  // Sequential processing
                           └─ transcribe (awaits WhisperKit)
                           └─ diarize (awaits FluidAudio)
                           └─ withCheckedContinuation (speaker naming UI)
                           └─ generate protocol (awaits Claude CLI Process)
```

### Detached Tasks

- `DualSourceRecorder` reads audiotap stdout in `Task.detached` (background I/O)
- `MuteDetector` polls AX API in `Task.detached(priority: .utility)` with `await MainActor.run` for state updates
- `ProtocolGenerator` reads stderr in `Task.detached`

### WhisperKit Load Deduplication

```swift
func loadModel() async {
    if let existing = loadingTask {
        await existing.value  // Second caller awaits first's task
        return
    }
    let task = Task { ... }
    loadingTask = task
    await task.value
}
```

### Process Awaiting Pattern (ProtocolGenerator)

Uses `terminationHandler` + `withCheckedContinuation` instead of blocking `process.waitUntilExit()`:
```swift
await withCheckedContinuation { continuation in
    process.terminationHandler = { _ in continuation.resume() }
}
```

## 7. File Storage

| Location | Contents |
|----------|----------|
| `~/.meeting-transcriber/` (`AppPaths.ipcDir`) | `pipeline_queue.json` (atomic queue snapshot), `pipeline_log.jsonl` (event log), `participants.json` (detected meeting participants) |
| `~/Library/Application Support/MeetingTranscriber/` (`AppPaths.dataDir`) | App data root |
| `~/Library/Application Support/MeetingTranscriber/recordings/` | Raw audio files: `*_app.wav`, `*_mic.wav`, `*_mix.wav` |
| `~/Library/Application Support/MeetingTranscriber/protocols/` | Output: `*.txt` (transcripts), `*.md` (protocols) |
| `~/Library/Application Support/MeetingTranscriber/speakers.json` | Speaker voice profile DB (array of `StoredSpeaker` with name + embedding) |
| `UserDefaults` (standard) | All `AppSettings` properties (watchTeams, pollInterval, whisperKitModel, etc.) |
| Temp directory | `pipeline_{uuid}/` working directories with resampled 16kHz WAVs (cleaned up after processing) |

## 8. Testing Strategy

### Test Count and Framework

341 Swift tests using XCTest + ViewInspector. Run with `cd app/MeetingTranscriber && swift test`.

### Mock/Protocol DI Pattern

Three protocols enable mock injection in tests:

| Protocol | Production | Mock |
|----------|-----------|------|
| `RecordingProvider` | `DualSourceRecorder` | `MockRecorder` — returns pre-prepared fixture WAV paths |
| `DiarizationProvider` | `FluidDiarizer` | `MockDiarization` — returns pre-set segments and embeddings |
| `ProtocolGenerating` | `DefaultProtocolGenerator` | `MockProtocolGen` — captures transcript/title/diarized for assertions |

Defined in `Tests/TestHelpers.swift`.

### Closure-based DI

- `MeetingDetector.windowListProvider: () -> [[String: Any]]` — inject mock window lists instead of `CGWindowListCopyWindowInfo`
- `WatchLoop.recorderFactory: () -> RecordingProvider` — inject `MockRecorder`
- `PipelineQueue.diarizationFactory: () -> DiarizationProvider` — inject `MockDiarization`
- `MuteDetector.muteStateProvider: ((pid_t) -> Bool?)?` — inject mock mute state

### Test Files

| File | Covers |
|------|--------|
| `WatchLoopTests.swift` | State machine, start/stop, callbacks (`@MainActor`) |
| `WatchLoopE2ETests.swift` | Full detect→record→enqueue flow with mocks (`@MainActor`) |
| `PipelineQueueTests.swift` | Enqueue, state changes, JSON logging, snapshot persistence (`@MainActor`) |
| `PipelineJobTests.swift` | Job model, codability, state labels |
| `MeetingDetectorTests.swift` | Pattern matching, confirmation counting, cooldown, idle filtering |
| `AudioMixerTests.swift` | Mixing, echo suppression, mute masking, resampling, WAV I/O |
| `DualSourceRecorderTests.swift` | Audiotap binary detection, timestamp formatting |
| `WhisperKitEngineTests.swift` | Token stripping, segment merging, hallucination filtering |
| `WhisperKitDualSourceTests.swift` | Dual-source transcription, delay alignment |
| `WhisperKitE2ETests.swift` | End-to-end transcription with real model (slow) |
| `FluidDiarizerTests.swift` | Speaker ID normalization, model availability |
| `SpeakerMatcherTests.swift` | Cosine distance, matching, DB persistence, migration |
| `DiarizationProcessTests.swift` | Speaker assignment by temporal overlap |
| `ProtocolGeneratorTests.swift` | Stream-json parsing, CLI resolution, file naming |
| `MuteDetectorTests.swift` | Timeline recording, mute state detection |
| `MenuBarViewTests.swift` | Menu bar UI (ViewInspector) |
| `SettingsViewTests.swift` | Settings UI (ViewInspector) |
| `SpeakerNamingViewTests.swift` | Speaker naming dialog, accessibility text fields |
| `AppSettingsTests.swift` | UserDefaults persistence, value clamping |
| `NotificationContentTests.swift` | Notification content for state transitions |
| `NotificationManagerTests.swift` | Setup, permission handling |
| `TranscriberStatusTests.swift` | Status model codability |
| `FormattingHelpersTests.swift` | Time formatting helpers |
| `KeychainHelperTests.swift` | Legacy keychain CRUD |

### Testing Patterns

- **`@MainActor` test classes** for WatchLoop and PipelineQueue tests (required because the classes are `@MainActor`)
- **Temp directories** created in `setUp()`, removed in `tearDown()` for file I/O tests
- **Fixture files** in `Tests/` (but most tests use in-memory data or mock results)
- **No real model tests by default** — WhisperKit E2E tests that require model download are separate and potentially slow
