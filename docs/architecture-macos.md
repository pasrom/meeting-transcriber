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
                │   concern controllers, settings, engines         │
                └────────┬─────────────────────────────────┬───────┘
                         │                                 │ optional
                         │                                 │ (#if !APPSTORE
                         │                                 │  + toggle/env)
                         │                                 ▼
                         │                  ┌──────────────────────────┐
                         │                  │  DebugRPCServer          │
                         │                  │  127.0.0.1:9876          │
                         │                  │  /state /healthz /metrics│
                         │                  │  /screenshot             │
                         │                  │  /action/openSettings    │
                         │                  │  /action/closeSettings   │
                         │                  │  /v1/* (automation API)  │
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
        │  • MicInputDetector │  │                │  │                    │
        │    (CoreAudio proc) │  │                │  │                    │
        └─────────────────────┘  └────────────────┘  └─────────┬──────────┘
                                                               │
        PipelineQueue per-job processing:                      │
        ┌──────────────────────────────────────────────────────▼─────────┐
        │ 1. Resample to 16 kHz mono (AudioMixer; AVAsset / ffmpeg fb)   │
        │ 2. (opt) FluidVAD silence-trim + timeline remap                │
        │ 3. Transcribe via active engine                                │
        │      └─ TranscribingEngine: WhisperKit | Parakeet             │
        │         (dual-source: each track separately, then merge)       │
        │ 4. (opt) Diarize via FluidDiarizer                             │
        │      └─ Mode: .offline | .sortformer | .nemotron               │
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
        │ 11. Job done; export to Notion in the background (optional)    │
        └────────────────────────────────────────────────────────────────┘
```

State writes to `AppPaths.dataDir`; IPC + queue snapshots to `ipcDir`.

---

## Source Files

### App Entry & UI

| File | Role |
|------|------|
| `AppLauncher.swift` | The actual `@main` — a process entry point that makes the one pre-launch diversion decision (e.g. `--localvqe-selftest`) before `MeetingTranscriberApp`/`AppState` construct, since a conforming `App` type cannot intercept its own launch |
| `MeetingTranscriberApp.swift` | UI shell — SwiftUI scenes, windows, NSOpenPanel, NSWorkspace. Observes `.showSettings` / `.closeSettings` / `.showSpeakerNaming` notifications for RPC- and pipeline-driven scene control; logs menu-triggered protocol-open and quit requests |
| `AppState.swift` | `@Observable @MainActor` composition root — wires the concern controllers (`engines`, `watching`, `pipeline`, `permissions`, `channelHealth`, `liveTranscription`, `rpcController`) and exposes the derived UI state (badge, status label) rather than owning it |
| `AppState+MicMute.swift` | The mic-mute menu-bar surface hoisted out of `AppState`, which has a type-check budget the analyze build enforces: `isMicMuted`, the `micMuteToggle` closure (nil when the active recorder can't mute), and `micMuteShortcut` from `AppSettings.micMuteHotkey` |
| `AppState+Termination.swift` | What a quit waits for, as `AppState` answers it for `AppTerminating` — reads `watching` and `pipeline` at quit time rather than capturing a loop or queue earlier, so it follows whichever ones exist by then (see `TerminationFlush`) |
| `LivenessMarker.swift` | Process-lifetime marker (issue #703): written at launch, touched once a minute, removed by a clean AppKit quit; the next launch reads it as `PreviousExit` to tell a crash, kill or power loss from a quit, which the per-recording marker cannot do for an idle app |
| `PreviousExitNotice.swift` | Wording of the launch-time notification for a run that ended without a quit: the window in which nothing was watching for meetings |
| `MenuBarView.swift` | Menu bar dropdown (state, actions, meeting info) |
| `QueueHeader.swift` | The heading and icon above the menu's job list, chosen pure from what the jobs are doing (working / waiting on the user / all finished / mixed) — same shape as `BadgeKind.compute`, so the precedence lives in one place and not in parallel `if` chains |
| `MenuStageProgressUpdater.swift` | Updates progress on the existing native menu item rather than rebuilding SwiftUI menu content on elapsed-time ticks or stage changes, which displaces the Cancel item's highlight |
| `ProtocolOpener.swift` | Opens local protocols with the default handler and prefers an already-running Notion desktop app for Notion pages, falling back to the default handler |
| `MenuBarIcon.swift` | Renders the animated waveform icon + badge overlays (permission, record-only, channel-silent) |
| `AppPickerView.swift` | App picker sheet for manual recording of any running app |
| `AudioImportTypes.swift` | File types offered by the batch-import and voice-enrollment `NSOpenPanel`s — single source of truth so the ffmpeg-gated vs. natively-decoded format lists stay pinned and testable |
| `A11yID.swift` | Shared accessibility-identifier namespace — one constant per control, referenced by the view modifier, ViewInspector tests, and the `/ui/press` allowlist |
| `SettingsView.swift` | Settings window — `NavigationSplitView` shell (sidebar of tabs) hosting seven topic-grouped sub-views in `Sources/Settings/` |
| `Settings/GeneralSettingsView.swift` | Startup (Launch at login, Start watching when the app opens = `AppSettings.autoWatch`) · Mode (Record-only) · Apps to Watch (Teams/Zoom/Webex/Browser/WeChat/Tencent Meeting/FaceTime/WhatsApp/Slack) · Detection (Poll Interval, Grace Period) |
| `Settings/AudioSettingsView.swift` | Microphone device · VAD (enabled + threshold) · Per-Channel Indicator |
| `Settings/MicMuteHotkeyRow.swift` | Settings → Audio row that captures the shortcut toggling mic mute during a recording — types the combination live, checks it against the system's own enabled shortcuts, and keeps the previous value with a reason on conflict |
| `GlobalHotkey.swift` | A key combination that works while another app is frontmost (Carbon HIToolbox registration); `AppSettings.micMuteHotkey`'s stored type, carrying the display name a key code alone can't reproduce without the keyboard layout that typed it |
| `Settings/TranscriptionSettingsView.swift` | ASR engine picker · engine-specific options · model status · Vocabulary section · Live transcription (PoC) toggle |
| `Settings/WhisperKitCustomModelDrafts.swift` | What is being typed into the custom WhisperKit model fields (repo, variant, folder), kept out of `AppSettings` until a field commits — one `@Observable` object rather than three `@State` strings so a ViewInspector test can read back what a field wrote |
| `Settings/LegacyWhisperModelsSection.swift` | The Storage section of the Transcription settings: WhisperKit models an earlier build left in `Documents`, shown only while there is something to remove or explain; nothing is pre-checked since a folder name alone can't tell this app's copy from another tool's |
| `Settings/LegacyWhisperModelsState.swift` | Backs `LegacyWhisperModelsSection`: lists the leftover variants and moves the ones the user picked to the Trash after confirming, off the main actor; failures are kept until the pane next appears so the row can say why a model is still listed |
| `Settings/SpeakersSettingsView.swift` | Diarization · Speaker Naming (open the naming window automatically, how long unnamed meetings wait) · Mic Speaker Name · Known Voices · Recognition Stats · Experimental: Diarization Tuning |
| `Settings/OutputSettingsView.swift` | Output tab: output folder · recording retention · Meeting Notes (notes language, prompt, output toggles) · AI Provider (provider, Claude CLI binary and key, connection picker, model) |
| `Settings/ProtocolAPIKeyDrafts.swift` | What is being typed into the meeting-notes API key fields, kept out of the Keychain until a field commits — bound straight to a field, every body evaluation was a Keychain read and every typed character a Keychain write, and a half-typed key was what a job starting meanwhile used |
| `Settings/OpenAIConnectionSection.swift` | Connection Settings section: selected connection's endpoint and API key, collapsed Advanced group (key placement, sampling overrides) and its `OpenAIAdvancedDisclosure` state |
| `Settings/OpenAIConnectionControls.swift` | Saved OpenAI-compatible connection picker with Add/Delete/Rename buttons |
| `Settings/OpenAIConnectionPrompts.swift` | State of the Add and Rename (name prompt) and Delete confirmation dialogs |
| `Settings/AdvancedSettingsView.swift` | Permissions · Diagnostics |
| `Settings/DiagnosticExportStatus.swift` | What Settings → Advanced says after Export Diagnostics — an export that found no recent entry still writes a file (header plus a notice saying why), so it counts as a success but must not read like a full one |
| `Settings/AboutSettingsView.swift` | Version · bundle identifier · build date · ffmpeg status · project link · Updates |
| `Settings/HelpBadge.swift` / `Settings/SettingsHelp.swift` | Reusable "?" help-popover badge + its shared copy, used across Settings sections |
| `Settings/View+RecordOnly.swift` | `recordOnlyDisabled(_:)` view modifier — dims + disables the Transcription/Protocol/VAD/Diarization sections when record-only mode is on |
| `Settings/DraftTextField.swift` | A text field whose value reaches its owner on Return or focus loss rather than on every keystroke — a plain `TextField` syncing a custom WhisperKit model field into the engine on each keystroke dropped the loaded model the instant a partial value happened to parse |
| `Settings/Notification+SettingsWindow.swift` | `closesSettingsWindow`: true for an `NSWindow.willCloseNotification` of the Settings window specifically — closing it only hides the window, so neither a focus change nor `onDisappear` reaches its fields, and the draft owners check for this in one place |
| `SpeakerNamingView.swift` | Speaker naming dialog after diarization |
| `SpeakerNamingView+Snippet.swift` | Reads only the clicked span's frames from the meeting's 16 kHz recording rather than decoding the whole file, which cost ~230 MB of samples per click on an hour-long meeting |
| `NamingJobPicker.swift` | Menu of the meetings waiting for names, above the naming dialog once more than one waits (a menu so the content-sized window stays narrow) |
| `NamingGraceKey.swift` | Identity of one keyboard-grace window in the naming dialog — what counts as "a new grace window" (data revision + pending-job count), so the gate re-locks when another job steals focus |
| `KnownVoicesView.swift` | Manage persisted speaker DB (rename, delete, merge) — embedded in `SpeakersSettingsView` |
| `RecognitionStatsView.swift` | Recognition stats display — aggregate counts from `recognition_log.jsonl` |
| `VoiceEnrollmentView.swift` | Voice enrollment sheet — seeds `speakers.json` from an existing audio file |
| `AppSettings.swift` | `@Observable` settings persisted to UserDefaults |
| `AppSettings+Computed.swift` | Values derived from stored `AppSettings` toggles, split out to keep `AppSettings.swift` under the line cap |
| `AppSettings+OutputDirectory.swift` | Everything derived from `customOutputDirBookmark`, split out to keep `AppSettings.swift` under the line cap |
| `AppSettings+Vocabulary.swift` | Custom-vocabulary file selection, sandbox bookmark resolution, and validation state — shared by both ASR engines |
| `AppSettings+OpenAIConnections.swift` | Add, select, rename and delete saved OpenAI-compatible connections |
| `AppSettings+TerminologyRules.swift` | Optional terminology-rules file: selection, bookmark, per-job read and the Settings status; the text area remains the default source |
| `AppSettings+WhisperKitModel.swift` | The WhisperKit model the settings ask for (variant + `WhisperKitModelOrigin`), and the custom-model validation states (`notConfigured`, `invalidRepository`, `folderReady`, …) the Transcription settings UI reads |
| `LegacyDefaultsMigration.swift` | One-shot carry-over of settings from the pre-rename bundle identifier, since `UserDefaults` is scoped per identifier |
| `LoginItemController.swift` | Launch at login via `SMAppService.mainApp`, behind `LoginItemRegistering` so tests use a fake; the status is read from macOS and never stored in `AppSettings` |
| `UpdateChecker.swift` | Checks GitHub releases for newer versions, drives the menu bar update badge |
| `UpdateInstallRoute.swift` | How an available update should reach this install: a Homebrew Cask install gets the `brew upgrade` command instead of the release DMG, since dragging the new app over a cask-installed copy leaves Homebrew's own record at the old version |
| `Settings/PickerLanguages.swift` | Language picker entries for WhisperKit and Parakeet language selectors |
| `LiveCaptionsState.swift` | `@Observable` live-captions state (per-channel hypotheses + finalised utterances) + RPC-wire types |
| `CaptionChannelFeed.swift` | `@MainActor` duration-bounded audio queue with one serialized consumer per channel, feeding a live-caption backend from the recorder's audio sinks |
| `LiveCaptionsOverlay.swift` | SwiftUI caption-bar content (recent finals + per-channel hypotheses) hosted in `LiveCaptionsWindow` |
| `LiveCaptionsWindowController.swift` | Borderless click-through NSPanel hosting the caption overlay; Option-drag moves it by screen-coordinate deltas, clamped to the screen visible frame (see `architecture/transcription.md`) |
| `CaptionBarPlacement.swift` | Pure placement decision `LiveCaptionsWindowController` makes on every `show()` and preset change: which attached screen a bar belongs to (whole frame) and where it is pushed back on-screen (visible frame, without menu bar and Dock) |
| `CaptionDragSession.swift` | Pure logic for which moves of the caption panel count as the user's drag and get saved, over screen-coordinate translation from the mouse and panel origins at drag start; an Option-click that never moved the panel is not a drop |
| `LiveCaptionsSize.swift` | Caption-bar size presets (Small/Medium/Large): font size paired with the fixed panel dimensions that fit it; `AppSettings.liveCaptionsSize` |
| `ProcessingStatsView.swift` | Read-only average per-stage processing durations from `stage_timing.jsonl` (Settings → Speakers) |

### Core Pipeline

| File | Role |
|------|------|
| `WatchLoop.swift` | Main orchestrator: detect → record → enqueue PipelineJob |
| `WatchLoop+MicMute.swift` | `toggleMicMute()` — flips the active recorder's mute and mirrors its resulting `isMicMuted` back onto `WatchLoop`, guarded by `canMuteMic` |
| `WatchLoop+Presentation.swift` | Title cleanup and the `TranscriberState` mapping, split out of `WatchLoop` for size |
| `WatchLoop+MeetingEnd.swift` | `MeetingEndReason` (ended vs. replaced by a new call) and `PhaseChangeCause` for why `WatchLoop.onStateChange` fired — leaving `.recording` for a call split is not a real stop |
| `WatchLoop+Quit.swift` | The parts of a quit `WatchLoop` answers for without needing its private state: where a recording the quit stopped goes, and what a stop that recorded nothing means while quitting; `finishForQuit` itself stays in `WatchLoop.swift` next to the watch task it waits for |
| `WatchLoop+ManualRecording.swift` | The poll loop that decides when a manually started recording ends, split out of `WatchLoop` |
| `WatchLoopEndPolicy.swift` | Pure decision logic for `waitForMeetingEnd` (grace-period / max-duration) |
| `WatchLoopState.swift` | Value-type snapshot of `WatchLoop`'s observable fields (for tests and RPC) |
| `ManualRecordingMonitorPolicy.swift` | Pure decision logic for manual recording stop conditions (process-died vs max-duration) |
| `MeetingDetecting.swift` | `MeetingDetecting` protocol + `DetectedMeeting` model |
| `MeetingDetector.swift` | Window title polling, pattern matching, confirmation counting, cooldown. Not the production detector (that is `CompositeMeetingDetector` over `PowerAssertionDetector` + `MicInputDetector`); production uses only its `systemWindowList` to look up meeting titles |
| `MeetingTitleMatcher.swift` | Compiled idle/meeting title regex semantics for one `AppMeetingPattern` |
| `PowerAssertionDetector.swift` | IOKit power assertion–based meeting detection (sandbox-safe); carries the Chrome WebRTC pattern for browser meetings (issue #503) |
| `PowerAssertionDetector+Diagnostics.swift` | "Saw something that looks like a meeting and did not act on it" diagnostic, split out of `PowerAssertionDetector` (line-cap) |
| `MicInputDetector.swift` | Third `MeetingDetecting` strategy: watches which processes hold `kAudioProcessPropertyIsRunningInput` via the Core Audio process-object API — covers call apps (WeChat, Tencent Meeting, FaceTime, WhatsApp, Slack Huddles) with no reliable power-assertion signal; each app opt-in and off by default. Also carries Safari browser meetings (WebKit GPU process attributed to Safari), selected by Browser Web Meetings and consent-gated |
| `MeetingPatterns.swift` | Regex patterns for Teams, Zoom, Webex, browser (Chrome WebRTC) |
| `BrowserConsentPolicy.swift` | Pure decision logic for the browser-meeting "ask before recording" prompt — decline cooldown (issue #503) |
| `ConsentAnswer.swift` | Three-way outcome of a consent prompt (yes / no / unanswered) — kept distinct from a `Bool` so a decline and a timeout get different re-prompt cooldowns (issue #543) |
| `BrowserConsentReadiness.swift` | Whether a browser-meeting consent prompt can actually reach the user — polls `NotificationVisibility` since the prompt is itself a notification and a broken notification channel can't report its own brokenness |
| `ConsentPromptCoordinator.swift` | Coordinates an async yes/no recording-consent prompt: register pending decision by id, resolve once via answer or timeout |
| `WatchLoop+Consent.swift` | Browser-meeting consent gate, split out of `WatchLoop`; only patterns with `requiresRecordingConsent` reach it |
| `DualSourceRecorder.swift` | Orchestrates AudioTapLib capture + mic, mixes tracks |
| `MicDelayNormalisation.swift` | Turns a microphone that started *before* the app tap (issue #693's negative `micDelay`) back into the alignment every downstream consumer already understands, by padding the app track once on disk rather than teaching a dozen consumers a new sign |
| `RecorderError.swift` | Why a recording could not start or produced nothing to process (`notRecording`, `noAudioData`, `unsupportedOS`, `permissionDenied`); its own file since `DualSourceRecorder.swift` is at the line cap, and `WatchLoop`/`WatchingController` throw and match it too |
| `RecordingProvider.swift` | Protocol abstraction over `DualSourceRecorder` for mock injection in `WatchLoop` tests |
| `WatchLoop+RecordOnly.swift` | Record-only output branch (moves WAVs + writes `RecordingSidecar`), split out of `WatchLoop` |
| `ProtocolResumePolicy.swift` | Decides what the snapshot restore does with a job interrupted mid-run: resume from the saved transcript, just finish, or run in full. Keys on the interrupted stage, never on "a transcript exists", because stage 1 writes a draft without speaker labels |
| `AudioPersistencePolicy.swift` | Decides per finished-job source file whether to relocate it into the output folder or leave it in place (staging-dir recording vs. user-picked import) |
| `TranscribingEngine.swift` | `TranscribingEngine` protocol + `mergeDualSourceSegments` default impl |
| `TimestampedSegment.swift` | A transcribed segment with timestamps and optional speaker label; every field is `var` on purpose, because copy-and-mutate across passes (delay shift, VAD remap, block merge) is what keeps fields a pass doesn't touch — a memberwise rebuild once silently dropped `suppressed` and reintroduced the duplicates it marks (issue #581) |
| `TranscriptNote.swift` | Puts a recording-level annotation at the top of a transcript, called from the one `transcriptText(note:micMuted:)` render path every transcript goes through — rendering composes the text fresh each time, so the note lands exactly once by construction, not by a guard at each write site |
| `DualTrackViability.swift` | Which tracks of a dual-source recording carry enough audio to transcribe, decided on frame count before any decode — an empty mic file used to throw WhisperKit's "at least 300ms of audio" error out of the entire job, discarding ten minutes on the other track with it (issue #724) |
| `DualTrackTranscription.swift` | What a dual-source job keeps from its two transcription passes; a track whose file itself fails (undecodable audio) is dropped the same way `DualTrackViability` drops an empty one, downgrading the verdict so echo dedup and both diarization runs treat it as not there |
| `TranscriptionFailureScope.swift` | Whether a transcription failure belongs to the file being transcribed or to the engine — only an allowlisted per-file failure lets a dual-source job keep the other track; an unclassified error (bad model load, broken init) ends the job rather than risk sending the second track to load the same broken model |
| `WhisperKitEngine.swift` | WhisperKit transcription engine (99+ languages, ~1 GB model) |
| `WhisperKitEngine+ModelLoad.swift` | The model load's retry loop, split out because the engine file is at the length limit — retried while the model asked for moved on during a pass, cancellation-aware per caller |
| `WhisperKitEngine+Segments.swift` | Turns WhisperKit's output into transcript segments, pure so the failure rules and hallucination filter are testable without a model — an empty `[]` here would misreport a model or audio-load error as "Empty transcript" |
| `WhisperKitLoadFailureReason.swift` | The one sentence a failed WhisperKit model load is reported with, in Settings and in the job's error text — only text this app owns or knows to be path-free is shown as-is, since the likely underlying errors carry a filesystem path that would otherwise reach a notification or the automation API |
| `WhisperKitLocalSnapshot.swift` | Where WhisperKit keeps downloaded models and whether a complete copy already sits there — the reason for the local-first load path: `WhisperKit.download` always GETs huggingface.co first, so a complete local model still fails when only that host is unreachable (issue #736) |
| `WhisperKitModelMigration.swift` | Moves WhisperKit models an earlier build downloaded into `Documents/huggingface` over to the current download base, so an existing install doesn't re-download a gigabyte; runs once per variant and process, off the main actor, awaited before the engine's local lookup |
| `WhisperKitModelOrigin.swift` | Where a WhisperKit model variant's files come from: a Hugging Face repo fetched into WhisperKit's cache, or a folder picked on disk and loaded in place; part of a model's identity since a fine-tune can keep its source model's folder name |
| `WhisperKitModelSource.swift` | The steps `WhisperKitEngine.loadModel()` takes to reach a usable pipe, named so a test can observe which ran; production resolves every step against WhisperKit itself, with the local-first step always tried before any download |
| `LegacyWhisperModelInventory.swift` | Finds and removes WhisperKit variant folders an earlier build left in `Documents/huggingface`, which iCloud keeps syncing (issue #640); only lists and trashes — removing is the user's decision, made in Settings |
| `WhisperDecodingClient.swift` | Narrow decode boundary used by `WhisperKitEngine` — production forwards to WhisperKit, tests capture the exact options passed |
| `WhisperVocabularyPrompt.swift` | Converts the shared custom-vocabulary file into a bounded WhisperKit decoder prompt (experimental, off by default) |
| `ParakeetEngine.swift` | NVIDIA Parakeet TDT v3 via FluidAudio (25 EU languages, ~50 MB, ~10× faster) |
| `ParakeetTokenGrouping.swift` | Pure token-grouping logic extracted from `ParakeetEngine` (testable) |
| `ParakeetVocabularyConfiguration.swift` | Identity of one Parakeet CTC vocabulary configuration (path + bookmark + file revision) and its preparation lifecycle |
| `VocabularyFileAccess.swift` | Resolves persisted sandbox access for the shared custom-vocabulary/terminology files, brackets reads with the matching security scope |
| `TerminologyNormalizer.swift` | Opt-in post-ASR canonical-spelling rules (`Canonical => variant \| variant`), engine-independent |
| `StreamingTranscriber.swift` | Per-channel live transcription actor (FluidVAD streaming → `engine.transcribeSamples` → partial/final captions) |
| `PipelineQueue.swift` | Decouples recording from post-processing, sequential job pipeline |
| `PipelineQueue+Stages.swift` | Per-stage job processing (transcribe → diarize → naming → protocol), split out of `PipelineQueue` (line-cap) |
| `PipelineQueue+Notion.swift` | Optional Notion export step and page tracking for protocol retries and re-exports |
| `NotionClient.swift` | Notion API client: page create and re-export, schema checks, request batching within Notion's limits, 429 backoff |
| `NotionClientError.swift` | Failures of the Notion client, with a fixed cause text shown in a job warning — never Notion's own response text, which can quote meeting content back |
| `NotionModels.swift` | Request and response types for the Notion API |
| `NotionExporting.swift` | Result of a meeting export to Notion: page ID, URL, any properties the target database had no column for, and whether this run updated an existing page rather than creating one |
| `NotionReplacePlan.swift` | Decides what a replace of an existing Notion page has to write and delete, from its current root blocks alone — recognises an interrupted retry's already-appended copy by visible content so a repeated abort doesn't cost one more copy of the protocol each time |
| `NotionRequestBatches.swift` | Keeps each request inside Notion's documented limits (blocks, elements, bytes, array counts, rich-text length) so a long meeting doesn't fail identically on every retry; a block that still breaks a limit is refused outright rather than sent to fail the same way again |
| `NotionExportDeadline.swift` | Bounds one export as a whole, since the client only limits each individual request and a replace of a long page is hundreds of them; the operation is cancelled but not awaited once the deadline or task cancellation wins the race |
| `MarkdownToNotionBlocks.swift` | Converts protocol Markdown and the transcript into Notion blocks |
| `JobOpenTarget.swift` | Decides what a finished job's Open action opens: the Notion page or a local file |
| `ProtocolOpener.swift` | Opens a job's target, preferring a running Notion desktop app |
| `Settings/NotionExportSettingsView.swift`, `Settings/NotionExportSettingsModel.swift` | Notion settings UI and its connection and schema state |
| `PipelineQueue+Recovery.swift` | Snapshot restore for `PipelineQueue` |
| `PipelineQueue+MeetingNotes.swift` | Retrying meeting notes that failed, from the saved transcript (per job and all at once), and notes-only jobs for transcripts the user picks |
| `PipelineQueue+Retention.swift` | The queue's side of recording retention: records what stage 3 moved, marks a recording due once its output is written, runs passes with the tracks its unfinished jobs hold |
| `PipelineController+Retention.swift` | When retention passes run (launch, hourly, after a rebuild, once the settings settle), and the pass before a queue is built |
| `RecordingRetention.swift` | Runs retention passes: decides on the main actor, deletes off it via `RecordingFileDeleter`, rechecks each delete |
| `RecordingRetentionPolicy.swift` | Pure decision per registry entry: delete, keep (with the reason) or drop |
| `RecordingRetentionRegistry.swift` | The list of relocated recordings retention may delete (`retained_recordings.json`), the only thing the cleaner acts on |
| `PipelineQueue+OrphanRecovery.swift` | Orphaned-recording recovery for `PipelineQueue`: the staging scan and the jobs it creates |
| `StagingRecoveryGate.swift` | One staging recovery at a time per process, each judging file ages from when it was asked for — two overlapping recoveries on one crashed stem could otherwise end with a microphone-only mix over the complete one |
| `PipelineQueue+EchoBleed.swift` | Warns when a dual-source recording carries the same speech on both tracks (loudspeaker bleeding into the microphone) — measurement half of the echo mitigation (issue #581) |
| `PipelineQueue+EchoCancellation.swift` | Removes the far end from the microphone track before anything reads it — cancellation half of the echo mitigation, the other branch of `EchoRemedy` |
| `EchoBleedDetector.swift` | Decides `.notMeasured` / `.clean` / `.affected` for a dual-source recording, from per-10s-window envelope correlation between the two tracks |
| `EchoSegmentClassifier.swift` | Per microphone segment, decides whether the app track's energy explains it (`.echoOnly`, suppressed from the transcript) or the local speaker also spoke (`.mixed`/`.ownVoice`, kept) |
| `EchoEmbeddingQuarantine.swift` | Holds mic-track speaker embeddings back from `speakers.json` on an echo-affected recording, so a voice learned from contaminated audio is never folded into a stored centroid |
| `EchoRemedy.swift` | Decides which of the two echo remedies (cancellation vs. transcript dedup) a recording gets — they do not compose |
| `EchoCancelling.swift` | Abstraction seam for acoustic echo cancellation; `LocalVQECanceller` is the concrete implementation |
| `EchoCancellationSelfCheck.swift` | Judges a cancellation run from the canceller's own per-window report — a difference between far-end and no-far-end windows, not a level, so a run that quietly removed nothing is caught |
| `EchoFrameChunking.swift` | Pure hop arithmetic for streaming a signal through LocalVQE's fixed-256-sample-hop frame API |
| `LocalVQECanceller.swift` | `EchoCancelling` implementation over the vendored LocalVQE static library (`CLocalVQE`) — owns the C context lifecycle, drives the streaming frame API hop by hop |
| `LocalVQECanceller+File.swift` | File-to-file half of `LocalVQECanceller` — the shape the pipeline calls |
| `LocalVQEModel.swift` | Resolves the bundled LocalVQE AEC model (`localvqe-*.gguf`) the canceller runs against; refuses to silently fall back when an override path is missing |
| `LocalVQESelftest.swift` | Hidden `--localvqe-selftest` CLI probe proving the statically linked library resolves its compute backend from inside a signed `.app` bundle (`#if !APPSTORE`) |
| `PipelineJob.swift` | Pipeline job model (waiting → transcribing → diarizing → generatingProtocol → done) |
| `PipelineSnapshot.swift` | Pure I/O helpers for persisting `PipelineQueue` jobs to disk (atomic rename) |
| `PipelineSnapshotStore.swift` | The one writer of a pipeline snapshot file, looked up by directory on every save, so a replaced `PipelineQueue` and its successor writing the same `pipeline_queue.json` land in save order rather than racing and putting older state back on disk |
| `PipelineEventLog.swift` | Append-only JSONL log of `PipelineQueue` job state transitions |
| `StageTimingStats.swift` | Per-stage wall-clock duration tracking, backs `ProcessingStatsView` |
| `ProcessedRecordingsLedger.swift` | File-backed ledger of mix-file paths that completed the pipeline (dedupes recovery re-processing) |
| `InFlightRunRegistry.swift` | Process-wide record of currently-executing pipeline runs, so a second `PipelineQueue` built while the first is still working can't double-start the same job/audio (issue #558) |
| `SnapshotWriterActor.swift` | Actor isolating pipeline queue snapshot writes (prevents main-actor stalls on macOS 26 rename deadlock) |
| `SpeakerNamingSession.swift` | Collaborator `PipelineQueue` calls for the speaker-naming work still owned by the queue, split out for size |
| `SpeakerNamingSessionDelegate.swift` | The delegate protocol the naming session reaches the queue through, split out of `SpeakerNamingSession` for size |
| `SpeakerNamingSession+Late.swift` | Late-confirm and late re-diarization paths for speaker naming |
| `SpeakerNamingSession+Handler.swift` | Re-invokes the injected naming handler that stands in for the dialog in tests and headless runs, mirroring the late-rerun re-invocation so the test path runs the exact same `completeSpeakerNaming` flow production does |
| `SpeakerNamingRefusal.swift` | Why the naming session did not take an answer from the naming dialog — the dialog shows the message and stays usable, instead of treating the answer as given and going dead until reopened |
| `SpeakerNamingRowState.swift` | `@Observable` per-presentation state of the naming rows, keyed by speaker label rather than row position, because rows are identified by label and a label's sorted position moves between jobs (the crash of issue #700) |
| `SpeakerNamingData.swift` | `PipelineQueue.SpeakerNamingData`/`.Segment`/`SpeakerNamingResult` value types, nested under `PipelineQueue` for source compat |
| `SpeakerSlotRename.swift` | Renames the speaker slot of rendered transcript lines (`[MM:SS] Speaker: text`); built and applied over the whole text once so a later rename can't hit the output of an earlier one, which used to put two swapped speakers under one name |
| `StaleNamingTimeout.swift` | How long a meeting may wait for speaker names before the launch-time cleanup accepts the automatic names (1 day · 7 days · never) |
| `SpeakerNamingStore.swift` | Disk persistence for a job's speaker-naming sidecars, keyed by per-job slug; pure I/O, no queue state |
| `SpeakerKey.swift` | Speaker identity in the dual-track pipeline: raw diarizer id + track; single home for the `R_`/`M_` prefix convention |
| `NamingWindowPolicy.swift` | Pins the "Name Speakers" window so it stays available while the user works in other apps (issue #504) |
| `NamingAnswerGate.swift` | Whether the naming dialog still takes an answer for the job it shows, and why the host refused the last one — per job rather than a single flag, and a refused answer does not count as given, so Confirm/Skip/Re-run stay live instead of going dead until the window reopens |
| `LiveTranscriptionController.swift` | Wires the per-channel live-caption pipeline (streaming or re-transcribe) to both `DualSourceRecorder` sinks (mic + app), feeds `LiveCaptionsState` |
| `LiveTranscriptionController+Sinks.swift` | The mic/app live sinks handed to `DualSourceRecorder` before `start()` — fan out each buffer into the channel's caption feed and its language-probe feed with no task spawn and no actor hop on the audio thread |
| `LiveTranscriptionController+Nemotron.swift` | Nemotron streaming-pipeline construction, split out for size; injectable factory for testing the build + model-load-failure fallback |
| `LiveTranscriptionController+LanguageProbe.swift` | Auto-detect captions with WhisperKit: holds caption audio, detects the recording's language, then installs Parakeet EOU (English) or re-transcribe; also the stop-time `flush()` |
| `CaptionLanguageProbe.swift` | Per-channel VAD probe that collects 4 s of speech for language detection, and the pure decision rule (probability ≥ 0.8, two English windows for EOU, up to 4 attempts) |
| `LiveTranscriptionCoordinator.swift` | `@Observable` coordinator: builds + arms `LiveTranscriptionController`, feeds `LiveCaptionsState` |
| `LiveCaptionPipeline.swift` | Per-channel live captioning strategy protocol (English EOU streaming \| Nemotron streaming \| WhisperKit/Parakeet re-transcribe) |
| `LiveCaptionsGate.swift` | Pure decision logic for live captions routing: master toggle + explicit engine language (`en` → English EOU streaming, a language in `LiveCaptionLanguages` → Nemotron streaming, auto-detect or any other language → re-transcribe or none) — shared by `AppState`, coordinator, and controller. Overlay visibility is a separate UI AND (`overlayVisible`); it is not a strategy input |
| `LiveCaptionLanguages.swift` | Nemotron tokenizer training coverage — prompt dictionary keys are spellings, not evidence of additional trained-language coverage; region is dropped where the tokenizer has one dialect, so a hand-set region-qualified code isn't recognised and falls back to re-transcribe |
| `LiveCaptionsWarmup.swift` | The live-caption model warm-up as Settings, the menu and `/state` show it (`idle`/`preparing(since:)`/`ready`/`failed`) |
| `StreamingCaptionSplitter.swift` | Text-only caption boundaries over a prefix-monotonic cumulative transcript; never resets the decoder — splits on a word count or a pause rather than re-running recognition |
| `EouStreamingCaptionSession.swift` | English low-latency streaming caption session via FluidAudio Parakeet EOU, backed by `UtteranceRingBuffer` |
| `NemotronStreamingCaptionSession.swift` | Multilingual (non-English) low-latency streaming caption session via FluidAudio Nemotron |
| `NemotronAsrManager.swift` | Production seam wrapping FluidAudio's Nemotron model + Silero VAD for `NemotronStreamingCaptionSession` |
| `UtteranceRingBuffer.swift` | Rolling 16 kHz sample buffer addressable by absolute ms timestamp (feeds streaming caption sessions) |
| `AsyncSerialGate.swift` | First-come-first-served async mutual exclusion that suspends waiters instead of blocking a thread; serialises Nemotron 3 runs and model loads |
| `ModelWarmupQueue.swift` | Serial FIFO gate for model warm-up loads — avoids compiling/loading the ASR engine and live-caption models concurrently at launch |
| `EngineModelState.swift` | App-owned model lifecycle state for a `TranscribingEngine`, decoupled from any ASR vendor's own enum |
| `EngineController.swift` | `@Observable @MainActor` engine selection + model lifecycle controller (language/vocabulary sync, preload) |
| `PipelineController.swift` | `@Observable` controller owning `PipelineQueue` lifecycle (wired by `AppState`) |
| `PipelineController+MeetingNotes.swift` | Generate Meeting Notes from Transcript: refuses without a notes provider, notifies about skipped files |
| `PipelineController+Notion.swift` | Rebuilds the queue at launch when a saved snapshot has a held-after-completion job (a failed or interrupted Notion export, or failed meeting notes) — the first queue is otherwise built by a user action, which that job has no other way to trigger |
| `PipelineController+ProductionEnvironment.swift` | How `PipelineController.QueueEnvironment` is wired in production, split out of `PipelineController.swift` for the `file_length` limit; a pure move with no behavioural difference from declaring it inline |
| `PipelineController+Quit.swift` | The pipeline side of a quit (see `TerminationFlush`): whether a snapshot write is still owed, and awaiting every snapshot write landing, including one a state change makes while the wait is already under way |
| `TranscriptPanelDelegate.swift` | Enables only `.txt` files in the Generate Meeting Notes from Transcript panel |
| `OutputDirectoryResolver.swift` | Decides a recording's output folder at the two seams that capture it (queue build, record-only write); notifies once per episode when the chosen folder cannot be reached and the default stands in |
| `WatchingController.swift` | `@Observable` controller owning `WatchLoop` lifecycle (wired by `AppState`) |
| `WatchingController+MicMute.swift` | Registers/unregisters the mic-mute global hotkey against the active `WatchLoop` whenever `canMuteMic` and `AppSettings.micMuteHotkey` allow it; notifies the user instead of silently doing nothing when the shortcut can't be registered |
| `WatchingController+Derived.swift` | `isWatching` / `isRecording` / `isManualRecording`, split out of `WatchingController` for size |
| `WatchingController+Detectors.swift` | Which detection strategies auto-watch runs, and how the "Apps to Watch" toggles filter them — line-cap split, pure and settings-driven |
| `WatchingController+WatchControl.swift` | The `/v1/watch` control surface: meeting watching as an idempotent resource a remote caller can drive |
| `WatchingController+RecordControl.swift` | The `/v1/record` control surface: microphone-only recording as an idempotent resource a remote caller can drive |
| `WatchingController+Quit.swift` | The watching side of a quit (see `TerminationFlush`): stops watching and hands whatever is recording, auto or manual, to the pipeline before the snapshot is flushed; a manual start still parked on the mic prompt gives up rather than waiting, since it has recorded nothing |
| `WatchingController+CaptionFlush.swift` | Starts the live-caption flush when a recording ends, split out because `WatchingController.swift` sits near the line cap; skipped for a call split, whose next call binds its caption feeds in the same main-actor stretch |
| `WatchingController+RecorderFactory.swift` | Builds the `recorderFactory` closure `WatchLoop` is handed: a fresh `DualSourceRecorder` per recording, with mic + app live sinks installed when live captions are eligible; `async` so the coordinator can await the prior recording's stop-time flush before reusing a kept EOU session |
| `WatchStatusDTO.swift` | Wire shape for `GET`/`POST /v1/watch` — the meeting-watching lifecycle as a small, stable projection |
| `RecordStatusDTO.swift` | Wire shape for `GET`/`POST /v1/record` — the microphone-recording lifecycle, same audience as `WatchStatusDTO` (Stream Deck key, Shortcut, shell script) |
| `WavHeaderRepair.swift` | Repairs unfinalized WAV files from crash-interrupted recordings (RIFF/data chunk size fix) |
| `FluidDiarizer.swift` | On-device speaker diarization via FluidAudio CoreML/ANE |
| `FluidDiarizer+SortformerEmbeddings.swift` | Post-hoc WeSpeaker embedding extraction for the Sortformer and Nemotron 3 modes — overlap-excluded masks feed `SpeakerMatcher` (DiariZen-style hybrid) |
| `FluidDiarizer+Nemotron.swift` | Nemotron 3 mode: the streaming loop that feeds a recording through `Nemotron3Diarizer` in 60 s pieces, one run at a time per instance; the model load sits behind an injectable seam and a process-wide load gate |
| `FluidDiarizer+NemotronModelLoad.swift` | The real Nemotron 3 model load (HuggingFace download, CoreML load on CPU + Neural Engine), the default of that seam |
| `SpeakerMatcher.swift` | Speaker embedding DB + cosine similarity matching |
| `SpeakerMatcher+Editing.swift` | Rename, delete and merge for Known Voices and the debug RPC, each through `mutateDB` — an edit against a DB that couldn't be used answers `notSaved` rather than reading as done, and one that found the DB corrupt and salvaged nothing still answers correctly rather than as a missing name |
| `SpeakerMatcher+UnreadableDB.swift` | Tells a missing `speakers.json` apart from one that exists but can't be used, and reports whether a change actually reached disk — the difference decides whether `mutateDB` may write, since a missing file starts empty but a present one must never be overwritten by a DB built without it |
| `SpeakerMatcher+Logging.swift` | Forensic match-decision logging (pseudonymized speaker names via `String.pseudonymized`) |
| `LiveSpeakerMatcher.swift` | Actor for real-time speaker matching per finalized live-caption utterance; same WeSpeaker CoreML model as batch path; caches mask frame count in `UserDefaults` for fast cold start |
| `StoredSpeaker.swift` | Codable speaker DB entry model (centroid + FIFO embeddings + metadata) |
| `DiarizationProcess.swift` | Diarization result types, DiarizationProvider protocol, speaker assignment (standard + dual-track) |
| `ProtocolGenerator.swift` | Shared protocol utilities: `ProtocolGenerating` protocol, prompts, file I/O, `ProtocolError` |
| `ArtifactRenamePlan.swift` | Plans the on-disk rename of one job's artifacts from one stem to another (`useAITitleForFilenames`); pure, from the closed suffix lists the pipeline writes with rather than a directory prefix scan, since a bare-title stem is a prefix of other jobs' stems |
| `MeetingNotesFailure.swift` | The kind of a meeting-notes failure, decided from the `ProtocolError` case, with the notification's fixed sentence and the sign-in hint |
| `ClaudeCLIProtocolGenerator.swift` | Claude CLI subprocess protocol generation (`#if !APPSTORE`) |
| `ClaudeCLIProtocolGenerator+Subprocess.swift` | One run of the CLI: pipes read through `ProcessOutput` so each ends at EOF or a drain grace after exit, whichever comes first, and the prompt is written to stdin through a channel stopped with the run so a CLI that never reads it can't hold the run up either |
| `ClaudeCLIProtocolGenerator+SafeMode.swift` | Starts the CLI with `CLAUDE_CODE_SAFE_MODE=1` so a protocol run does not load the user's own global `CLAUDE.md`, hooks, skills or plugins — a reminder written for the user's coding sessions was otherwise showing up in a meeting's protocol (measured with CLI 2.1.285) |
| `ClaudeCLIProtocolGenerator+SessionPersistence.swift` | Keeps the meeting transcript out of the CLI's own session store under `~/.claude/projects/`, which left left a second, unplanned copy of a confidential document per protocol run; `--no-session-persistence` plus the auto-memory variable removes it down to an empty project folder |
| `ClaudeCLIProtocolGenerator+ToolRestriction.swift` | Starts the CLI with `--tools ""` and `--strict-mcp-config` so a sentence in the untrusted meeting transcript can't reach a built-in tool, the shell, or any MCP server the user configured for their own sessions |
| `OpenAIProtocolGenerator.swift` | OpenAI-compatible API protocol generation (Ollama, LM Studio, etc.) |
| `OpenAIConnection.swift` | One saved OpenAI-compatible connection (key in the Keychain) |
| `RecordingSidecar.swift` | Metadata sidecar written next to recordings in record-only mode |
| `RecordingFileSuffix.swift` | Filename suffix constants for dual-source recordings (`_app.wav`, `_mic.wav`, `_mix.wav`) |
| `MicMuteLog.swift` | The mute times of a recording still in progress, on disk beside its tracks; `stop()` hands them over and removes the file, so one still present means the recording never stopped, which is what lets a recovered job explain and filter the muted stretch |
| `SilentRecordingMonitor.swift` | Pure state machine detecting fully-silent recordings (both channels below threshold) |
| `ChannelHealthMonitor.swift` | Pure state machine for per-channel asymmetric silence detection (one channel live, other dead) — levels + hysteresis, drives the menu-bar tint |
| `ChannelHealthController.swift` | `@Observable` controller polling channel dBFS levels and driving `ChannelHealthMonitor` |
| `ChannelHealthController+Alerts.swift` | The notification copy `ChannelHealthController` posts for each capture fault and for a recording that stayed silent; pure static builders kept apart from the polling so the controller file stays under the length cap |
| `ChannelHealthController+LogLines.swift` | The diagnostics lines `ChannelHealthController` writes, as pure testable strings — never a device name, UID or meeting title, so a "no notification was shown" field report can be told apart from "no verdict was reached" or "monitoring never started" |
| `ChannelFaultMonitor.swift` | Pure state machine deciding whether a channel has stopped delivering, from per-buffer ages rather than levels (issue #614) — drives the "Capture Channel Silent" notification, deliberately separate from the level-based tint |
| `PairedImportPanelDelegate.swift` | `NSOpenPanel` delegate + accessory view for paired dual-source file import |
| `PairedRecordingResolver.swift` | Groups recording URLs into dual-source groups (app + mic pairs, singletons) for reimport |
| `AudioCapturing.swift` | The part of `AudioTapLib.AudioCaptureSession` one recording drives — the consumer-side protocol `DualSourceRecorder` depends on |
| `E2EMicFault.swift` | Which microphone fault the fault-injection build injects, chosen per launch from an env var so one bundle serves every lane that needs one; compiled only with `-DE2E_FAULT_INJECTION`, which also keeps the variable name itself out of every shipped binary |
| `DualSourceRecorder+BuildRecording.swift` | Turning a finished capture session into the files the pipeline consumes, split out of `DualSourceRecorder` |
| `DualSourceRecorder+TapPIDs.swift` | Which processes a recording taps, split out of `DualSourceRecorder.swift` for the line cap — resolves every PID under the matched app's bundle via `ProcessTreeEnumerator`, root PID first, falling back to `[rootPID]` alone when enumeration finds nothing |
| `RecordingSource.swift` | What a single recording captures (app PID + mic on/off), replacing an untyped tuple |
| `ManualRecordingInfo.swift` | Info about a manually started recording session, as opposed to one a detector started |
| `ManualRecordingRequest.swift` | What the user asked `WatchingController` to record by hand (app-picker vs. microphone-only) |
| `AppPickerStartState.swift` | Whether the app picker can start a recording, and if not, why |
| `MicrophoneRecordingAvailability.swift` | Whether the menu bar's "Record Microphone" item can start a recording, and if not, why |
| `ConsentDenyList.swift` | Persisted "Never for this app" browser-meeting consent denials (issue #503 follow-up), checked before the decline cooldown |

### Audio Processing

| File | Role |
|------|------|
| `AudioMixer.swift` | Resampling, mixing, echo suppression, WAV I/O |
| `AudioMixer+AssetFallback.swift` | Tier 2 of `loadAudioAsFloat32`, split out of `AudioMixer.swift` for size — decodes the first audio track via `AVAssetReader` as mono Float32 at the target rate, the rescue path behind `AVAudioFile` |
| `AudioMixer+Streaming.swift` | Decodes and resamples a long import incrementally so it never needs one buffer for the whole recording — `AVAudioPCMBuffer` caps byte capacity at `UInt32`, which a four-hour 48 kHz stereo file exceeds even though its frame count still fits `AVAudioFrameCount` |
| `AudioConstants.swift` | Shared audio pipeline constants (target sample rate) |
| `FFmpegHelper.swift` | ffmpeg CLI detection + 16 kHz mono WAV conversion fallback for file-import formats AVAsset can't decode |
| `FluidVAD.swift` | VAD preprocessing via FluidAudio Silero v6 — silence trimming + `VadSegmentMap` timeline remapping |
| `LiveAudioResampler.swift` | Streams live `LiveAudioBuffer` through `AVAudioConverter` → 16 kHz mono Float32 (feeds `StreamingTranscriber`) |
| `SampleRateDriftDetector.swift` | Watches actual vs declared CATap sample rate (catches USB hot-plug + HFP↔A2DP renegotiation drift) |
| `tools/audiotap/Sources/AppAudioCapture.swift` | CATapDescription + IOProc → FileHandle |
| `tools/audiotap/Sources/AppAudioCapture+PIDTranslation.swift` | Translates PIDs to CoreAudio `AudioObjectID`s (multi-process tap for Electron apps like Teams 2.x) |
| `tools/audiotap/Sources/AppAudioCapture+DebugLogging.swift` | Per-buffer dBFS/RMS logging helpers extracted from `AppAudioCapture` (line-cap split) |
| `tools/audiotap/Sources/AppAudioCapture+LiveSink.swift` | Live-buffer forwarding from CATap IOProc into `LiveAudioBuffer` sinks (line-cap split) |
| `tools/audiotap/Sources/AppAudioCapture+AggregateDescription.swift` | The CFDictionary describing the private aggregate device wrapping a process tap (line-cap split from `AppAudioCapture`) |
| `tools/audiotap/Sources/AppAudioCapture+Restart.swift` | Output-device-change restart path: off-main-queue, generation-tagged, deadline-bounded attempts (issue #588; line-cap split) |
| `tools/audiotap/Sources/SilentTrackObserver.swift` | Notices when the app track enters and leaves a run of exact zeros while buffers keep arriving, so the transition is in the log and not only the end state (issue #672) — the sensor; whether a run should trigger a rebuild is a separate question answered by `SilentTrackWatchdogPolicy` |
| `tools/audiotap/Sources/AppAudioCapture+SilentTrackDiagnostics.swift` | The log call sites for the silent-track instrumentation (issue #672), split from `AppAudioCapture.swift` for the line cap — one triage line per recording is unconditional, the 5 s cadence line stays gated |
| `tools/audiotap/Sources/SilentTrackDiagnostics.swift` | Owns the queue, re-entrancy guard and observer state the silent-track instrumentation needs that a value type cannot hold (issue #672); its own queue because the HAL reads must not share `writeQueue`, the main queue, or the restart queue |
| `tools/audiotap/Sources/SilentTrackWatchdogPolicy.swift` | Decides when a run of exact zeros on the app track is worth rebuilding the tap for, how often, whether a rebuild helped, and when to give up (issue #672 part 2); also covers a tap that never delivered a first buffer at all (issue #693) |
| `tools/audiotap/Sources/SilentTrackWatchdogLimits.swift` | The watchdog's limits that user-facing copy names (issue #672), public so help text and notifications interpolate the same values the policy enforces rather than restating them |
| `tools/audiotap/Sources/AppAudioCapture+SilentTrackWatchdog.swift` | Wiring and log lines for the opt-in silent-track watchdog: rebuilds the tap and aggregate through the device-change restart path once the judgement in `SilentTrackWatchdogPolicy` says so (issue #672 part 2, issue #693) |
| `tools/audiotap/Sources/NoFirstBufferProbeSchedule.swift` | When an app-audio capture that has delivered nothing is probed, and what the resulting diagnostic line says — a fourth probe point added because the three that shipped with issue #693 each miss a trigger |
| `tools/audiotap/Sources/AppTapSession.swift` | Owns one tap attempt's HAL resources (tap, aggregate device, IOProc) and their release ordering, injectable for testing without hardware |
| `tools/audiotap/Sources/AggregateRunState.swift` | What the aggregate device says about itself and which output device it is bound to (issue #693) — `AudioDeviceStart` returning `noErr` says the object exists, not that IO is running, and only `kAudioDevicePropertyDeviceIsRunning` tells the two apart |
| `tools/audiotap/Sources/TappedProcess.swift` | One process the tap was built from, kept so its CoreAudio state can be read again later rather than re-translating its PID, which can answer about a different object after the PID is reused |
| `tools/audiotap/Sources/ProcessOutputState.swift` | What a tapped process's CoreAudio object says about its output (issue #672) — `isRunningOutput` separates a dead tap from a silent one but not a muted far end from a dead tap; `devices` says whether its output actually reached the device the tap follows |
| `tools/audiotap/Sources/MicCaptureHandler.swift` | AVAudioEngine → WAV |
| `tools/audiotap/Sources/MicCaptureHandler+Restart.swift` | Mic-side device-change restart path: off-main-queue, generation-tagged, deadline-bounded attempts (issue #588; same pattern as `AppAudioCapture+Restart`) |
| `tools/audiotap/Sources/MicCaptureHandler+FirstStart.swift` | Bounds the microphone's first `start()` the same way a restart is bounded (issue #778): off the main queue, under a generation from `RestartArbiter`, since the call that brings up an engine can loop inside AVFAudio and never return (issue #588) |
| `tools/audiotap/Sources/MicCaptureHandler+DebugFault.swift` | Debug fault injection for the e2e lanes (issues #379, #724/#706); inert unless a `DebugTapFault` was injected |
| `tools/audiotap/Sources/MicCaptureHandler+Mute.swift` | Silences or restores the mic track from the next buffer on without reopening the input, since reopening is what can flip a Bluetooth headset's profile and wedge (issues #693, #588) — the mute button's `setMuted`/`muteIntervals` |
| `tools/audiotap/Sources/MicMuteTimeline.swift` | When the microphone was muted, in seconds of the written track rather than wall-clock time, since that is the timeline the track's transcript is on; `Codable` so a crash mid-mute can be closed at the end of the surviving track on recovery |
| `tools/audiotap/Sources/MicCaptureHandler+Progress.swift` | Whether microphone capture is getting anywhere, measured by comparing the mach time of the last buffer against an injected clock rather than a raw age, since five restarts a second make "no buffer since arming" indistinguishable from "no buffer at all" |
| `tools/audiotap/Sources/MicCaptureProgressPolicy.swift` | What a microphone capture that has not delivered should do next: wait, restart, or give up and tell the user |
| `tools/audiotap/Sources/MicCaptureStall.swift` | The microphone's stall as the capture layer reports it (issues #724, #706): released after going without audio for the whole budget — tracked separately from whether the user has been told, since a revival that stalls again must still raise it |
| `tools/audiotap/Sources/MicEngineSession.swift` | Everything mic capture that touches `AVAudioEngine`/CoreAudio, behind a protocol so `MicCaptureHandler` is testable without hardware; one session = one engine lifetime, discarded and rebuilt on restart |
| `tools/audiotap/Sources/MicChannelMap.swift` | Decides when a discrete multi-channel mic input needs an explicit converter `channelMap` — `AVAudioConverter`'s implicit downmix silently writes digital silence for most non-stereo layouts |
| `tools/audiotap/Sources/MicConverterFactory.swift` | Builds the tap → WAV converter for one mic capture, applying `MicChannelMap`'s explicit channel selection when needed |
| `tools/audiotap/Sources/DefaultInputListenerRegistrar.swift` | Registers and removes the mic handler's listener for the system's default-input-device changes — a seam so a test can watch it add/remove a listener without one reaching the real host, where a device change would restart capture under the test's feet |
| `tools/audiotap/Sources/MicConfigurationChangePolicy.swift` | What a microphone engine's input unit is bound to (device, hardware-side format) and what a configuration-change check finds on a pinned engine |
| `tools/audiotap/Sources/MicDevicePinOutcome.swift` | What came of pointing a mic engine's input unit at the configured device — its own type because a rejected pin and an accepted one used to produce byte-identical log output while recording ran on the wrong microphone |
| `tools/audiotap/Sources/MicInputDevice.swift` | The input device the mic diagnostics name — resolves the device the engine was actually pointed at, not just the system default, which used to misname the recording microphone (issue #724) |
| `tools/audiotap/Sources/AudioCaptureSession.swift` | Orchestrator (start/stop, computes micDelay) |
| `tools/audiotap/Sources/AudioCaptureConfiguration.swift` | What one capture records and how — the single list a new capture option is added to |
| `tools/audiotap/Sources/AudioCaptureResult.swift` | Result struct |
| `tools/audiotap/Sources/LiveAudioBuffer.swift` | Real-time audio sample snapshot yielded from capture callbacks (CATap IOProc + AVAudioEngine input tap) |
| `tools/audiotap/Sources/CurrentLevel.swift` | Pure function: dBFS level read with staleness decay (stale tap → silence) |
| `tools/audiotap/Sources/LevelPublisher.swift` | Cross-thread dBFS slot: audio callback writes, UI thread reads |
| `tools/audiotap/Sources/AppNoiseFloorSensor.swift` | Rolling 120 s share of app-tap samples in buffers below one 16-bit step; raises a flag at 90%, clears at 50% (issue #699). Warning only: feeds `ChannelFaultMonitor`'s `noiseFloor` fault, never the shared energy definition or the tap itself |
| `tools/audiotap/Sources/ChannelSignalAges.swift` | How long ago a channel last delivered a buffer, and last delivered one carrying signal — a single dBFS reading can't tell "dead", "muted", and "quiet room" apart, ages can (feeds `ChannelFaultMonitor`) |
| `tools/audiotap/Sources/DebugRMSReporter.swift` | Throttled RMS accumulator/reporter for audio debug logging |
| `tools/audiotap/Sources/Helpers.swift` | `machTicksToSeconds`, `getDefaultOutputDeviceUID`, `writeAllToFileHandle` |
| `tools/audiotap/Sources/MicRestartPolicy.swift` | Pure decision logic for mic engine restart on device change |
| `tools/audiotap/Sources/CaptureRestartRetryPolicy.swift` | Retry/backoff policy for a failed capture restart, shared by both the app-audio and mic channels (issue #379) |
| `tools/audiotap/Sources/RestartArbiter.swift` | Bounds how long a *single* restart attempt may run — generation-tagged so a wedged attempt that eventually returns is rejected rather than adopted, and forbids output-file creation forever once timed out (issue #588) |
| `tools/audiotap/Sources/OutputDeviceChangeCoordinator.swift` | State machine for output device change + tap restart flow |
| `tools/audiotap/Sources/ProcessTreeEnumerator.swift` | Enumerates all PIDs under an `.app` bundle (Electron/Teams child-process support) |
| `tools/audiotap/Sources/ProcessResponsibility.swift` | Groups a helper process with the app macOS holds *responsible* for it — needed for Safari, whose call audio comes from WebKit XPC services outside `Safari.app` rather than child processes under its bundle (issue #524); private symbol via `dlsym`, so it is `nil` under `APPSTORE` |
| `tools/audiotap/Sources/ChromiumHelperFilter.swift` | Keeps a Chromium/Electron app's audio service (`--utility-sub-type=audio.mojom.AudioService`) in the tap set and drops its other helpers; tapping the video-capture service alongside stalled the tap before its first IO cycle (issue #791). Leaves the set alone when no audio service is found |
| `tools/audiotap/Sources/ProcessArguments.swift` | Reads another process's argv via `KERN_PROCARGS2` (pure parser + live sysctl reader); empty when the kernel will not say, which every caller reads as "no opinion" |
| `tools/audiotap/Sources/SystemSettingsPaths.swift` | User-facing System Settings navigation paths (e.g. Screen Recording pane, renamed in macOS 15), kept in one place so the tap-error hint, permission UI, and channel-health notification name it identically |
| `tools/audiotap/Sources/SampleRateQuery.swift` | Pure functions for sample rate detection and cross-validation |
| `tools/audiotap/Sources/AppAudioCapture+RateQueries.swift` | The sample-rate property queries and the priority ladder between them, split out of `AppAudioCapture.swift` for the line cap — answers what rate a device *says* it runs at, which `DeliveredRateTracker` can disagree with (issues #673, #82) |
| `tools/audiotap/Sources/DeliveredRateTracker.swift` | Measures the rate the tap is actually delivering rather than asking once at the first IOProc callback, so a device that renegotiates in place without a default-device change is still followed (issue #673) |
| `tools/audiotap/Sources/AVAudioNode+SafeInstallTap.swift` | Safe `installTapOnBus` wrapper catching `NSException` via `CExceptionCatcher` (issue #379) |
| `tools/audiotap/Sources/AppAudioCapture+Resampling.swift` | Capture-time resampling for CATap buffers (line-cap split from `AppAudioCapture`) |
| `tools/audiotap/Sources/AppAudioCapture+TapError.swift` | Tap-creation error mapping (line-cap split from `AppAudioCapture`) |
| `tools/audiotap/Sources/AppAudioCapture+TapBuffer.swift` | Which buffer of the aggregate's input carries the process tap (issue #803) — a sub-device with its own inputs (an audio interface, a Loopback device) puts its input streams ahead of the tap's, so reading the first buffer can record the interface's microphone as the app track instead |
| `tools/audiotap/Sources/CExceptionCatcher/` | Obj-C module catching AVFoundation `NSException` from `installTapOnBus` |
| `tools/audiotap/Sources/DebugTapFault.swift` | Fault-injection config for mic device-change E2E to verify NSException recovery |
| `tools/audiotap/Sources/MicCaptureHandler+Timeline.swift` | Timeline tracking for `MicCaptureHandler` across device-change restarts |
| `tools/audiotap/Sources/StreamingMonoResampler.swift` | Streaming mono resampler for the live 16 kHz audio path |
| `tools/audiotap/Sources/TapFormatResolver.swift` | Derives mic tap format from hardware format (prevents installTap channel-count mismatch) |
| `tools/audiotap/Sources/TimelineAnchor.swift` | Wall-clock timeline anchor across device-change restarts (keeps track aligned to real time) |

### Support

| File | Role |
|------|------|
| `TranscriberStatus.swift` | Status + state enum models |
| `AppPaths.swift` | Centralized path constants (ipcDir, dataDir, logSubsystem, speakersDB) |
| `AXHelper.swift` | Shared accessibility API helper (used by ParticipantReader) |
| `NotificationManager.swift` | macOS notifications |
| `SilentNotifier.swift` | No-op `AppNotifying` implementation for CLI targets and tests that don't need notifications |
| `NotificationUrgency.swift` | How urgently a notification must reach the user — two cases (vs. the five `UNNotificationInterruptionLevel` offers) mapped to whether a given notification should pierce Focus |
| `NotificationScheduling.swift` | Port over the `UNUserNotificationCenter` slice `NotificationManager` uses, so posting/registration is testable against a fake scheduler |
| `NotificationRingBuffer.swift` | Bounded, thread-safe log of recently-posted notifications (`#if !APPSTORE`) |
| `DateFormatter+FilenameStamp.swift` | `DateFormatter` pinned to Gregorian calendar + POSIX locale for filename timestamp stamps |
| `UserDefaults+Bool.swift` | A stored flag, or a fallback when the key was never written or holds something that isn't one — not `object(forKey:) as? Bool`, since an untyped `defaults write` stores the string "1", which that cast reads as missing while `bool(forKey:)` elsewhere reads it true (issue #814) |
| `KeychainHelper.swift` | Legacy keychain CRUD (token now file-based) |
| `RecognitionStats.swift` | Recognition event model + `recognition_log.jsonl` reader/writer — backs `RecognitionStatsView` |
| `Permissions.swift` | Mic/accessibility permissions, project root detection |
| `PermissionRow.swift` | Permission status row UI component (icon, detail, help popover) |
| `PermissionHealthCheck.swift` | TCC verdict + live probe → `PermissionStatus`; drives exclamation badge overlay |
| `PermissionHealthCheck+MicProbeDeadline.swift` | Bounds the live microphone probe the same way the recording's own first start is bounded (issue #778) — `-[AVAudioEngine inputNode]` can loop inside AVFAudio and never return (issue #588), and an unbounded probe parked the awaiting health check for good |
| `NotificationVisibility.swift` | What the notification centre will actually *do* with a posted notification (alert style, Time Sensitive, scheduled delivery) — authorisation alone can read `.authorized` while the prompt never shows |
| `ParticipantReader.swift` | Teams participant extraction via Accessibility API |
| `DebugRPCServer.swift` | Embedded HTTP RPC server core (routing, auth) for shell-driven inspection. `#if !APPSTORE`, opt-in via Settings → Advanced → Local Automation API or `MEETINGTRANSCRIBER_DEBUG_RPC=1`. Bearer-token + Origin reject; binds 127.0.0.1 only. Endpoint handlers split into companion files below (line-cap) |
| `DebugRPCServer+V1.swift` | `/v1` versioned automation API routing + response envelopes (`POST /v1/transcribe`, `/v1/jobs`, naming, `/v1/watch`, `/v1/record`) |
| `DebugRPCServer+Metrics.swift` | `GET /metrics` handler — cumulative CPU/RAM/instruction counters via `proc_pid_rusage` |
| `DebugRPCServer+Screenshot.swift` | `GET /screenshot` handler (PNG of the largest visible window via ScreenCaptureKit) |
| `DebugRPCServer+UITree.swift` | `GET /ui/tree` handler — read-only accessibility tree of an allowlisted window |
| `DebugRPCServer+UIPress.swift` | `POST /ui/press` handler — presses an allowlisted control via in-process `AXUIElementPerformAction`, or via `MouseInjection` when `"via":"click"` is requested |
| `DebugRPCServer+UIType.swift` | `POST /ui/type` handler — types into an allowlisted plain-text field via `KeyboardInjection` |
| `DebugRPCServer+AXElement.swift` | Shared self-pid `AXUIElement` tree walk backing `/ui/tree` and `/ui/press` |
| `DebugRPCServer+MeetingNotes.swift` | `POST /v1/jobs/<id>/notes/retry`, `POST /v1/jobs/notes/retry` and `POST /v1/jobs/notes/generate`, wired through `MeetingNotesActions` |
| `SpeakerDBActions.swift` | Outcome and closure types of the speaker-DB `/action/*` routes (line-cap split from `DebugRPCServer.swift`) |
| `KeyboardInjection.swift` | Types text into the app's own UI via posted key events (not an AX set-value, which wouldn't fire a SwiftUI `TextField` binding) — backs `POST /ui/type` |
| `MouseInjection.swift` | Clicks a point in the app's own UI via posted mouse events (real hit-testing, unlike some `kAXPressAction` controls that report success without effect) — backs `POST /ui/press` `"via":"click"` |
| `HTTPRequest.swift` | Minimal HTTP/1.1 request parsing for `DebugRPCServer` (pure value type, line-cap split) |
| `HTTPResponse.swift` | Minimal HTTP/1.1 response serialization for `DebugRPCServer` (pure value type, line-cap split) |
| `RPCResourceMetrics.swift` | JSON-serializable resource-usage snapshot of the running process, backs `GET /metrics` |
| `JobStatusDTO.swift` | Wire + persisted shape for `GET /v1/jobs/<id>` (live or terminal job status, result paths, and optional Notion page details) |
| `NamingStatusDTO.swift` | Wire shape for `GET /v1/jobs/<id>/naming` — per-speaker auto-name suggestion + speaking time + participants |
| `IdempotencyStore.swift` | Bounded FIFO map of `Idempotency-Key` → created job IDs for the `/v1` enqueue routes |
| `TerminalJobStore.swift` | File-backed store of recent finished-job statuses (survives queue reaping + app restart) |
| `AppSettings+RPC.swift` | Builds the read-only settings projection for the debug RPC `/state` endpoint |
| `AppState+RPC.swift` | Builds `RPCStateSnapshot` from live `AppState` for the `/state` endpoint (`#if !APPSTORE`) |
| `RPCStateSnapshot.swift` | JSON-serializable RPC state snapshot type (`#if !APPSTORE`) |
| `Bundle+AppVersion.swift` | Bundle extension: `appVersion` + `gitCommitHash` from `Info.plist` |
| `DiagnosticExporter.swift` | Reads log entries and writes shareable `.log` file (Settings → Advanced → Export Diagnostics) |
| `PersistentDiagnosticLog.swift` | Persistent `log stream` subprocess with sliding-window restart policy for long-term log retention |
| `DiagnosticsLogging.swift` | Seam for the lines a field report is triaged from, so a test can assert a line was written at the point it claims to be rather than only what it would say; lines arrive fully built and contain nothing private by construction, so the production sink writes them `.public` |
| `String+LogRedaction.swift` | String extensions: `.pseudonymized` (SHA-256 4-hex prefix) and `.redactedName` for log privacy |
| `FileManager+OwnerOnly.swift` | `FileManager` extension: owner-only file permission constant (`rw-------`) as single source of truth |
| `SecurityScopeAccess.swift` | Opens and closes security-scoped access to a user-picked folder — must be opened on the URL object resolved from the bookmark itself, never a derived or rebuilt URL, which carries no scope of its own and silently works unsandboxed while opening nothing sandboxed |
| `SingleFlight.swift` | Single-flight async deduplication coordinator (concurrent callers await one shared run and receive its outcome) |
| `BoundedProcess.swift` | A subprocess run with a time limit — stops it with SIGTERM then, after a grace period, SIGKILL, both sent to the process group the child leads so whatever it started in that group stops with it |
| `ProcessOutput.swift` | Reads a subprocess's pipes with no thread blocked in a read; a process the child started can hold a pipe open after the child exits, so each stream can also be ended from outside, at the latest a drain grace after the process exits |
| `TerminationFlush.swift` | What AppKit's quit holds open for: stops watching, stops and enqueues an in-flight recording, then waits for the snapshot write that enqueue produced to land — the one shutdown path, since Cmd-Q, logout, shutdown and an AppleScript quit never go through the menu's own Quit handler |
| `RPCServerController.swift` | `@Observable` controller owning `DebugRPCServer` lifecycle (`#if !APPSTORE`, wired by `AppState`) |
| `PermissionsController.swift` | `@Observable` controller for permission health checks (wired by `AppState`, re-runs on activation) |

### Companion CLIs

| Path | Role |
|------|------|
| `tools/mt-cli/` | Thin Swift client for `DebugRPCServer`. Subcommands: `state`, `healthz`, `screenshot`, `open-settings`, `close-settings`, `confirm-browser-consent`, `wav-verdict`, `seed-speaker`, `rename-speaker`, `delete-speaker`, `merge-speakers`, `ui-tree`, `ui-press`, `watch`, `record`. Reads token from `~/Library/Application Support/MeetingTranscriber/.rpc-token`. Skill doc at `tools/mt-cli/skill.md`. |
| `tools/meeting-simulator/` | Test fixture: spawns a fake meeting window for E2E detection tests |

---

## State Machine

```
WatchLoop:     idle → watching → recording → watching (enqueues PipelineJob)
PipelineQueue: waiting → transcribing → [diarizing] → generatingProtocol → done (Notion export runs in the background; 60s auto-remove after any pending export, deferred while a native menu is open)
                                                                            ↳ error
```

**Transitions** are observable via `WatchLoop.state` and `PipelineQueue.jobs`, triggering:
- Menu bar icon/label updates
- macOS notifications (recording started, protocol ready, error)

### Menu Bar Icon Animations

`BadgeKind.compute(watchLoopActive:watchLoopState:transcriberState:activeJobState:updateAvailable:permissionProblem:consentPending:)` is the pure function that maps the combined `WatchLoop` + pipeline state into one of `BadgeKind.inactive | .recording | .transcribing | .diarizing | .processing | .userAction | .done | .error | .updateAvailable`. `MenuBarIcon.image(badge:permissionOverlay:recordOnlyOverlay:)` then renders the matching animation frame.

| State | GIF | Triggered by | Code path |
|-------|-----|--------------|-----------|
| **Idle** | <img src="menu-bar-idle.gif" width="60"> | `WatchLoop.state == .idle / .watching` and `PipelineQueue` empty | `BadgeKind.inactive` |
| **Recording** | <img src="menu-bar-recording.gif" width="60"> | `WatchLoop.state == .recording` (waveform bars bounce) | `BadgeKind.recording` |
| **Transcribing** | <img src="menu-bar-transcribing.gif" width="60"> | `PipelineJob.state == .transcribing` or `TranscriberState.recordingDone` (bars morph into text glyphs) | `BadgeKind.transcribing` |
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

A persistent small red dot in the bottom-right corner indicates that **Record-only mode** is enabled (`AppSettings.recordOnly == true`). In this mode `WatchLoop.enqueueRecording()` moves dual-source WAVs into `<outputDir>/recordings/` together with a `<basename>_meta.json` `RecordingSidecar` and skips the entire post-processing pipeline (VAD, transcription, diarization, protocol). Intended for fleet topologies where macOS clients capture and a separate machine (e.g. a Linux GPU host via Syncthing) processes the audio. The sidecar's `trigger` field (`auto` | `manual`, schema version 2) tells that consumer which call site produced the recording, so it can treat a short auto-detected capture (likely a false trigger) differently from a short deliberate manual one.

Like the permission badge, the dot is rendered as a persistent overlay on top of whatever primary animation is currently active — so the mode is always clearly indicated whether the app is idle, recording, or running anything else. **Precedence:** when both apply, the red exclamation (permission badge) wins, because a permission problem actually breaks recording while record-only is a deliberate user choice.

### Per-channel asymmetric-silence indicator

When one capture channel goes silent while the other is still carrying audio for longer than the configured debounce window, the waveform bars in the menu bar are tinted **red** to surface the half-broken capture at a glance. `MenuBarIcon.image(..., micSilentOverlay:appSilentOverlay:)` paints the **top half** red when the mic channel is the silent one and the **bottom half** red when the app-audio channel is the silent one. When both apply, both halves are red (effectively all-red bars). Like the permission badge, this overlay forces non-template rendering so the red stays red in dark mode.

The flags driving this overlay (`AppState.micSilentActive` / `AppState.appSilentActive`) are flipped by a ~10 Hz polling task that reads `WatchLoop.activeRecorder?.{mic,app}LevelDBFS` and feeds the values into a pure `ChannelHealthMonitor` state machine. The monitor uses two dBFS thresholds — `silenceThresholdDBFS` (-60) and `speechThresholdDBFS` (-50) — with hysteresis: an episode only starts when one channel is below silence *and* the other is above speech, and only resolves when the supposedly-silent side crosses back above the speech threshold. Transient dips into the dead zone between the thresholds (natural pauses between syllables) keep the debounce timer running rather than resetting it.

**Settings → Audio → Per-Channel Indicator** turns the tint on or off (default on); the **Warn after** slider (30–300 s, default 90 s) sets the window. The toggle governs the tint alone: notifications are posted whether or not it is on, because a user who finds the red icon distracting is not asking to be left uninformed about a dead capture channel. The per-channel notification comes from `ChannelFaultMonitor`, which asks whether that channel has stopped delivering (no buffers, or buffers of digital zeroes) rather than whether it is quiet. On the app channel it also reports a floor below one 16-bit step (`AppNoiseFloorSensor`, issue #699): buffers that carry energy, so they never read as digital silence, but for two minutes at least 90% of them sit below 2^-15 RMS, which a tap of a silent meeting app never delivers. The symmetric `Recording Appears Silent` still comes from `SilentRecordingMonitor` and its dBFS thresholds, so it remains level-based and can fire on a call in which nobody is speaking; moving it onto the ages needs the gap between the two monitors closed first.

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

**Key:** CATapDescription is TCC-gated: it needs the "Audio Recording" grant (`NSAudioCaptureUsageDescription`) or, as a fallback, Screen Recording. With neither, the tap starts without an error and captures silence. Handles output device changes by recreating tap automatically.

**Start order (issue #693):** `AudioCaptureSession.start()` opens the microphone first and the app tap second, and the order is load-bearing. Opening the input takes a Bluetooth headset out of A2DP into its call profile; with the tap opened first, the disturbance landed underneath an aggregate device that had been created and started but had not yet run its first IO cycle, and the tap then delivered nothing for the rest of the recording (no IO callback, zero bytes, no error). Measured with a throwaway probe that is not in this repository: 9 failures in 30 starts with the tap first, 0 in 30 with the microphone first, which bounds what is left rather than proving it gone. **The full argument, including what the order does and does not guarantee and the three accepted costs, is the doc comment on `AudioCaptureSession.start()`; it is kept in one place on purpose.** Downstream, the measured `micDelay` is now normally negative (the microphone leads), which `MicDelayNormalisation` turns into a padded app track and a reported delay of 0; two cases it does not cover are a dual-source recording whose `_mic.wav` turns out unreadable, where the raw negative value is still what gets reported, and a crash-recovered recording, which `DualSourceRecorder.recoverCrashedRecording` rebuilds with a hard-coded `micDelay: 0` and therefore does not realign at all.

**Restart bounding (issue #588):** a device-change restart on either channel can wedge inside AVFAudio/CoreAudio and never return (e.g. `AVAudioEngine.inputNode` looping on a dangling Bluetooth sub-device held by coreaudiod). `RestartArbiter` bounds how long a single restart attempt may run — attempts carry a generation and run off the main queue, so a result from a wedged attempt that eventually returns is rejected rather than adopted. `CaptureRestartRetryPolicy` bounds how many attempts are made and is shared by both channels. A channel that gives up tells the user directly (`AudioCaptureSession`/`DualSourceRecorder` expose which one) instead of only decaying to silence, which the asymmetric-silence detector would otherwise misreport as a routing/mute problem rather than a channel that is gone for good.

**Safari support (issue #524):** the app-audio tap targets processes via macOS's *responsible-process* attribution (`ProcessResponsibility`) as well as bundle-path enumeration (`ProcessTreeEnumerator`) — Safari's call audio comes from WebKit XPC services outside `Safari.app`, unlike Electron/Chrome helpers that live inside their own bundle.

### Processing (DualSourceRecorder.stop())

```
App temp: already 16kHz mono float32 (resampled in-IOProc at capture time)
  → Save app.wav (16kHz mono)
  → Load mic.wav (already 16kHz from MicCaptureHandler)
  → Echo suppression (RMS-based gate, 20ms windows)
  → Delay alignment (prepend zeros by MIC_DELAY)
  → Mix (average tracks)
  → Save mix.wav (16kHz mono)
```

All recordings are normalized to 16kHz at capture time — no resampling needed in the pipeline.

### Echo Mitigation (issue #581)

The RMS-based echo suppression above is a capture-time gate; it does not catch a loudspeaker recording where the remote voices bleed into the microphone track after both tracks are already saved. Two independent, non-composing remedies run in the transcribe stage, decided per recording by `EchoRemedy`:

- **Detection first, always:** `EchoBleedDetector` (`PipelineQueue+EchoBleed.swift`) scores per-10s-window envelope correlation between the app and mic tracks, centred on the recorder's own `micDelay`, and reports `.notMeasured` / `.clean` / `.affected` as `PipelineJob.echo` (surfaced on `GET /v1/jobs/<id>`).
- **Cancellation (off by default):** `LocalVQECanceller`, over the vendored `CLocalVQE` static library, removes the far end from the microphone *audio* before transcription. `EchoCancellationSelfCheck` judges the run from the canceller's own per-window report before its output is adopted.
- **Transcript dedup (opt-in, off by default, and only on an `.affected` verdict):** `EchoSegmentClassifier` decides per mic segment whether the app track's energy explains it; explained segments are marked `suppressed` and left out of the transcript, so the far end isn't written twice. It ships off because a local speaker who only ever talks while the far end does is explained away and removed with them, which `EchoSegmentClassifierTests` pins as an expected failure.
- **Embedding quarantine:** on an `.affected` recording, `EchoEmbeddingQuarantine` holds mic-track speaker embeddings back from `speakers.json`, since a voice learned from contaminated audio would otherwise be folded permanently into a stored centroid.

Full design rationale (why the two remedies can't compose, the model provisioning, and the self-check semantics) lives in `docs/architecture/echo.md`.

### Mic Mute

A dual-source recording's microphone can be muted mid-recording from a configurable global
hotkey (`GlobalHotkey`, captured in **Settings → Audio** via `Settings/MicMuteHotkeyRow`) or from
the menu bar, whenever the active recorder has an open microphone to mute (`canMuteMic`). The
toggle is local to this app: it is this recording only, the call itself and the OS microphone
indicator are unaffected, so remote participants are not told and still see the mic as live unless
they notice the silence.

Muting does not reopen the microphone input. `MicCaptureHandler+Mute` silences (and later restores)
the track from the next buffer on while the `AVAudioEngine` keeps running, because reopening the
input is what can flip a Bluetooth headset out of its call profile and wedge (issues #693, #588) —
not a risk a mute button should take. The muted stretch is written to the mic track as exact zeros
like any other silence.

The mute times themselves are tracked separately from the audio, by `MicMuteTimeline`: closed
intervals plus one still-open interval while muted, in seconds of the *written track* rather than
wall-clock time, since that is the timeline the track's transcript is on. `DualSourceRecorder`
writes the timeline to a `MicMuteLog` sidecar beside the in-progress tracks on every toggle, so a
crash mid-mute cannot lose the mute times, and removes it once the recording stops normally. A log
still present at the next launch means the recording never stopped: the staging recovery scan
(`PipelineQueue+OrphanRecovery` via `MicMuteLog.forRecovery`) closes its still-open interval at the
end of the recovered microphone track and carries the result into the recovered job. In record-only
mode the intervals travel instead inside the `RecordingSidecar` JSON written next to the moved WAVs,
for whenever that recording is later picked up for processing.

Downstream, the pipeline treats a muted stretch as nothing to transcribe rather than silence to
describe: segments falling inside a mapped mute interval are dropped from the transcript
(`[TimestampedSegment].removingMuted`), a mute marker line is inserted at each stretch
(`transcriptText(note:micMuted:)`), and a recording muted throughout fails fast with
`PipelineError.micMutedThroughout` instead of being sent to the ASR engine.

---

## Transcription

### Engine Selection

`TranscribingEngine` protocol abstracts ASR backends. `AppSettings.transcriptionEngine` selects the active engine.

| | WhisperKit | Parakeet TDT v3 |
|---|---|---|
| **Languages** | 99+ | 25 European |
| **Model size** | ~800 MB–1.5 GB | ~50 MB |
| **Speed (M4 Pro)** | ~10–20× RTF | ~110× RTF |
| **Language selection** | Manual or auto-detect | Auto-detect only |
| **Timestamps** | Per-segment | Per-token |
| **macOS** | 14+ | 14+ |
| **Hallucinations** | Can occur | Minimal |

### WhisperKit Engine

- **Model:** `openai_whisper-large-v3-v20240930_turbo` (CoreML/ANE)
- **Pre-loading:** Model downloaded and loaded at app launch (when selected)
- **Lazy fallback:** `ensureModel()` loads on-demand if not ready

### Parakeet Engine

- **Model:** NVIDIA Parakeet TDT v3 via FluidAudio (CoreML/ANE)
- **Pre-loading:** Model downloaded and loaded at app launch (when selected)
- **Token grouping:** `groupTokensIntoSegments` groups per-token timings into sentence-level segments (split on `. ! ?` or 20 tokens)

### Modes

1. **Single source:** `transcribeSegments(audioPath:)` → `[TimestampedSegment]` with start/end/text
2. **Dual source:** `transcribeSegments(appAudio:)` + `transcribeSegments(micAudio:)` → `mergeDualSourceSegments(appSegments:micSegments:)` → `[TimestampedSegment]` merged by timestamp
   - App segments labeled "Remote"
   - Mic segments labeled with user's mic name (default "Me")
   - `mergeDualSourceSegments` is a protocol extension on `TranscribingEngine` — shared by all engines

### Post-processing (WhisperKit only)

- **Token stripping:** Regex `<\|[^|]*\|>` removes `<|startoftranscript|>`, `<|en|>`, etc.
- **Hallucination filtering:** Skip consecutive identical segments

### Custom Vocabulary & Terminology Normalization

- **Custom vocabulary** is one shared one-term-per-line file (`AppSettings.customVocabularyPath`, resolved through `VocabularyFileAccess` for sandbox bookmark access), not per engine. `AppSettings.customVocabularyEnabled` switches it on or off for both engines. Parakeet applies it via CTC boosting. WhisperKit applies it via `WhisperVocabularyPrompt` turning the file into a bounded decoder-prompt hint — WhisperKit shares its 224-token decoder context between that prompt and generated tokens, so a dense recording can lose whole sentences to it; Parakeet is the recommended engine for vocabulary boosting.
- **Terminology normalization** (`TerminologyNormalizer`) is a separate, engine-independent post-ASR pass, applied to transcript segments right after transcription: opt-in `Canonical => spoken variant | another variant` rules, configured in Settings → Transcription → Vocabulary → Canonical terminology, either in the text area or in an optional rules file that is read again at the start of every job (details in `docs/architecture/transcription.md`).

---

## Live Captions (PoC)

Optional in-meeting caption overlay, "Enable live transcription during recording" in Settings →
Transcription (`AppSettings.liveTranscriptionEnabled`, off by default; enabling downloads a ~0.6 GB
model on first use behind a consent alert). Nested "Show caption overlay"
(`AppSettings.liveCaptionsOverlayEnabled`, default on) hides `LiveCaptionsOverlay` without
stopping the pipeline; `LiveCaptionsState` and `/state.liveCaptions` keep updating.

`LiveCaptionsGate.strategy(liveEnabled:engineLanguage:engineSupportsLive:)` is the pure decision
function — shared by `AppState`, `LiveTranscriptionCoordinator`, and `LiveTranscriptionController`
— that picks the per-channel backend from the active engine's **explicitly configured** language
(not auto-detect):

| Engine language | Strategy | Backend |
|---|---|---|
| `en` | English streaming | `EouStreamingCaptionSession` (FluidAudio Parakeet EOU) |
| a language Nemotron was trained on (`LiveCaptionLanguages`) | Nemotron streaming | `NemotronStreamingCaptionSession` / `NemotronAsrManager` (FluidAudio Nemotron multilingual) |
| auto-detect (`nil`) or any other language | re-transcribe | `StreamingTranscriber` via the active engine's `transcribeSamples`, if supported |
| auto-detect or any other language + engine doesn't support live re-transcribe | none | captions off |

The gate's re-transcribe for auto-detect is where a recording starts. With WhisperKit active,
`LiveTranscriptionController` first detects each recording's language and streams English through
Parakeet EOU instead (see `docs/architecture/transcription.md`).

Both streaming sessions are engine-independent (they drive their own FluidAudio models directly),
so they're available even when the active `TranscribingEngine` has no live re-transcribe hook.
`LiveTranscriptionController` wires the resolved per-channel pipeline to both `DualSourceRecorder`
sinks (mic + app) and feeds `LiveCaptionsState`, which backs the `LiveCaptionsOverlay` window.
`ModelWarmupQueue` serializes model warm-up loads (ASR engine + streaming models) so they don't
compile/load concurrently at launch.

---

## Diarization

### FluidDiarizer (On-device)

On-device speaker diarization using FluidAudio (CoreML/ANE). No HuggingFace token or Python subprocess needed. Models downloaded automatically on first run (~50 MB); Nemotron 3 mode downloads its own ~200 MB model the first time it is used.

Three modes selected via `AppSettings.diarizerMode`:
- **`.offline`** (default) — `OfflineDiarizerManager`, standard speaker segmentation
- **`.sortformer`** — `SortformerDiarizer`, overlap-aware diarization (handles simultaneous speech); speaker embeddings extracted post-hoc via `FluidDiarizer+SortformerEmbeddings` using overlap-excluded WeSpeaker masks
- **`.nemotron`** — `Nemotron3Diarizer`, NVIDIA's Nemotron 3 Diarization (an 8-speaker streaming Sortformer), overlap-aware for up to eight speakers; the `fast128` preset (~200 MB, downloaded on first use). The recording is streamed through the model in 60 s pieces, so the mel spectrogram of the whole file is never held; embeddings come from the same post-hoc WeSpeaker extraction as `.sortformer`. Like `.sortformer`, it ignores `numSpeakers`

Flow: `FluidDiarizer.run(audioPath, numSpeakers)` → selected diarizer → `DiarizationResult` with segments, speaking times, and speaker embeddings.

**Experimental tuning:** Five `OfflineDiarizerConfig` parameters are exposed in `AppSettings` and editable in Settings → Speakers → Experimental: Diarization Tuning: `clusterThreshold` (0.6), `warmStartFa` (0.07), `warmStartFb` (0.8), `minSegmentDurationSeconds` (1.0), `excludeOverlap` (true). All default to FluidAudio community values.

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

`SpeakerNamingView` shown when diarization finds speakers: by itself while "Open naming window automatically" (`AppSettings.autoOpenSpeakerNaming`) is on, otherwise when the user opens it from "Name Speakers…" in the menu bar. Each row shows label, auto-matched name, speaking time, and audio playback. All rows are editable. Supports re-run with different speaker count.

---

## Protocol Generation

### Provider Selection

`AppSettings.protocolProvider` selects the active provider:
- **`.claudeCLI`** — Claude CLI subprocess (`#if !APPSTORE`)
- **`.openAICompatible`** — Any OpenAI-compatible HTTP API (Ollama, LM Studio, llama.cpp, etc.)
- **`.none`** — Skip LLM generation; save transcript only

`AppSettings.includeFullTranscriptInProtocol` and
`AppSettings.saveRawTranscriptSeparately` default to `true` to preserve the
legacy output. Their values are captured when a job enters the queue, so a
later settings change affects only subsequent recordings. The raw `.txt` and
verbatim segment sidecar are deleted only after a job completes successfully
with a saved protocol. If protocol generation is disabled, fails, or the job
ends in an error, the raw transcript is retained with a warning; recordings are
governed by their separate retention policy.

`AppSettings.useAITitleForFilenames` (off by default, captured per job the same
way) names a job's files after the meeting title in the generated protocol's
heading instead of the timestamped slug: `sprint_planning.md`,
`sprint_planning.txt`, `sprint_planning_mix.wav` and so on. It can only act once
a protocol exists, so with the `.none` provider, a failed generation, or a
heading that is a placeholder, bracketed or has no alphanumerics, the
timestamped names stay. The rename moves every artifact of the job in both
`protocols/` and `recordings/`, found from the closed suffix lists rather than a
prefix scan, because a bare-title stem is a prefix of other jobs' stems. A title
is taken only if none of its artifacts exist, otherwise `_<shortID>` is
appended, and nothing is overwritten. If any move fails, the ones already done
are undone and the job keeps its old stem and paths.

`AppSettings.protocolLanguage` (default `"German"`) is substituted into the prompt as `{LANGUAGE}`. Custom prompts can also use `{MEETING_DATE}` (`YYYY-MM-DD`) and `{MEETING_TIME}` (`HH:mm`), derived from the captured recording start time. Imports and recovery jobs resolve those time placeholders to `Unknown` rather than their enqueue or processing time. Only recordings with a captured start receive the authoritative meeting-metadata block, so existing custom prompts receive reliable temporal context without needing to add the placeholders.

### Notion Export

When `AppSettings.notionExportEnabled` is on, `PipelineQueue` saves the generated
protocol locally first, moves the job to `done`, then exports the Markdown to the
selected Notion database in the background, so a slow Notion cannot hold up the next
job and a quit costs no second LLM call. The local copy is kept by default;
`notionSkipLocalMarkdownOnSuccess` removes it only after a successful export or
retry. Export failures add a job warning with a short cause and keep the local copy.
`notionSpeakerTagsEnabled` separately opts in to sending confirmed speaker names as
tags and defaults off. Date and Tags are written only when the selected database
has recognized columns.

The job records its Notion page and database IDs as soon as the page is created,
so retries and protocol re-exports can use the same destination. Re-export after
speaker renaming replaces the page's root content with the current protocol. New
content is appended before prior root blocks are archived: a failed append keeps
the previous content, and a retry reconciles any partial new content. A successful
re-export replaces manual edits to the app-owned page, except blocks of a type
that never holds protocol text (`NotionReplacePlan.keptTypes`: sub-pages,
databases, media, embeds, links), which stay, above the new content. A delete
that answers 404, or 400 for an archived block, counts as done once a fresh
listing no longer shows the block; Notion answers 404 for lost access as well.
The client pins Notion API version `2022-06-28`; databases with multiple data
sources are rejected rather than guessing which source should receive the meeting.

A failed export retains the completed job and its local Markdown backup across
queue cleanup and app restarts, even if the original audio is no longer present.
The menu's **Retry Notion Export** action is available when export is enabled and
the backup file exists; it reads the saved protocol and reuses the recorded page
ID for the same database, plus saved speaker names when tags are enabled. It does
not transcribe audio or generate a new protocol. Success clears the export-failure
warning and starts the normal 60-second completed-job lifetime. If a completed
job's in-progress export is interrupted, recovery marks it failed with an
"interrupted when the app quit" warning for this same retry path; see
`pipeline.md` for when these jobs come back at launch. If the app stops during protocol generation for a pending export,
recovery regenerates from the saved corrected transcript when the saved
transcript and naming state permit protocol-only recovery, even if an older
Markdown file exists.

When a Notion target is routed and the Notion desktop app is running, the app
receives the page handoff. Otherwise, the original Notion URL is opened with
the system's default handler. If the desktop app rejects the handoff, the
original URL is also opened with the default handler. Local protocol files
always use the default handler.

### Claude CLI Invocation

```bash
/usr/bin/env claude -p - --output-format stream-json --verbose --model sonnet --tools "" --strict-mcp-config
```

- **Input:** Meeting metadata + protocol prompt (with variables substituted) + transcript piped to stdin
- **No tools:** `--tools ""` and `--strict-mcp-config` start the session without built-in tools or MCP servers, since the transcript is untrusted text. A CLI too old for these options fails the protocol with a message asking for an update; it is never run without them
- **Output:** Stream-json parsed line-by-line (content_block_delta + assistant message)
- **Environment:** `CLAUDECODE` env var stripped to allow nested invocation; `CLAUDE_CODE_DISABLE_AUTO_MEMORY=1` and `CLAUDE_CODE_SAFE_MODE=1` forced, so the run uses no auto memory and does not load the user's `CLAUDE.md`, hooks, skills or plugins, while the `env` block and `apiKeyHelper` of their `settings.json` still apply
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
[appended when enabled]
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
| Protocols | `~/Downloads/MeetingTranscriber/` by default, or the folder chosen in Settings → Output |
| IPC | `~/Library/Application Support/MeetingTranscriber/ipc/` (`~/.meeting-transcriber/` is only read once, as a migration source) |
| Speaker DB | `~/Library/Application Support/MeetingTranscriber/speakers.json` |
| WhisperKit models | `~/Library/Application Support/MeetingTranscriber/huggingface/` |
| Pipeline logs | `~/Library/Application Support/MeetingTranscriber/ipc/pipeline_queue.json`, `pipeline_log.jsonl` |
| AudioTapLib | Linked as SPM library (no separate binary) |

---

## Testing Hooks

| Component | Injection Point |
|-----------|----------------|
| MeetingDetector | `windowListProvider` closure (mock window list) |
| PowerAssertionDetector | `assertionProvider` + `windowListProvider` closures |
| MicInputDetector | `processProvider` + `windowListProvider` + `responsibleAppProvider` closures |
| DiarizationProvider | `diarizationFactory` closure in PipelineQueue |
| ProtocolGenerating | `protocolGenerator` protocol in PipelineQueue |
| RecordingProvider | `recorderFactory` closure in WatchLoop |
| ProtocolGenerator | `claudeBin` parameter |
| NotificationManager | `NotificationScheduling` port over `UNUserNotificationCenter` (fake scheduler in tests) |
| ConsentPromptCoordinator | Injected timeout clock; pure register/resolve-once API (no UI dependency) |
| LiveCaptionsGate.strategy | Pure static function — call directly with any input combination, no controller needed |
| AppNotifying | `notifier` parameter in `AppState.init` (`SilentNotifier` default, `RecordingNotifier` in tests) |
| BadgeKind.compute | Pure static function — call directly with any input combination, no WatchLoop needed |
| DebugRPCServer | Out-of-process inspection via HTTP. Debug endpoints: `GET /state /healthz /metrics /screenshot`, `POST /action/openSettings /action/closeSettings`. Versioned automation API under `/v1` (`POST /v1/transcribe`, `POST /v1/jobs`, `GET /v1/jobs/<id>`, `GET`/`POST /v1/jobs/<id>/naming`, `POST /v1/jobs/<id>/naming/skip`, `POST /v1/jobs/<id>/notes/retry`, `POST /v1/jobs/notes/retry`, `POST /v1/jobs/notes/generate`, `GET`/`POST /v1/watch`, `GET`/`POST /v1/record`); see `docs/automation-api.md`. `#if !APPSTORE`; started by the Settings toggle or the env flag. `boundPort` exposes OS-assigned port for in-process integration tests. `tools/mt-cli/` is the matching inspection CLI. `scripts/test_rpc.sh` is a live smoketest (build + launch + drive + assert). |

---

## Permissions

| Permission | Required For | Notes |
|------------|-------------|-------|
| Screen Recording | Real meeting titles; fallback grant for the app-audio tap. Detection does not need it | CGWindowListCopyWindowInfo |
| Microphone | Mic recording | AVAudioEngine |
| Accessibility | Participant reading (optional; not applicable in the App Store build) | Teams AX tree |
| Audio Recording | App audio capture | CATapDescription (Screen Recording also accepted) |

### Permission health check + badge overlay

`PermissionHealthCheck` verifies each of the three TCC permissions the build uses by combining the system verdict with a live probe (e.g. `CGWindowListCopyWindowInfo` returning non-empty window titles for Screen Recording). Each permission resolves to `PermissionStatus.healthy | .denied | .broken | .notDetermined | .notApplicable` (the last is the App Store build's Accessibility verdict: that build does not use the grant, so it is not probed and raises no badge or notification) — `.broken` means "TCC says allowed but the probe disagrees," which happens when macOS hasn't actually wired the permission through and the user needs to toggle it off and on in System Settings.

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

`SettingsView` is a thin `NavigationSplitView` shell: a sidebar lists the tabs, the detail pane shows the selected one. Each tab is a self-contained `View` in `Sources/Settings/` owning only the bindings it needs and its own local `@State`. The settings window is resizable (`minWidth: 760, idealWidth: 860, maxWidth: 1000`).

| Tab | Sections | Bindings | Local state |
|---|---|---|---|
| **General** | Startup · Mode · Apps to Watch · Detection | `settings` | — |
| **Audio** | Microphone · VAD · Echo · Per-Channel Indicator · Mic Mute Shortcut | `settings` | `audioDevices` |
| **Transcription** | Engine + per-engine options + status + idle-model retention | `settings`, three engines | — |
| **Speakers** | Diarization · Speaker Identity · Known Voices · Recognition Stats · Experimental: Diarization Tuning | `settings`, `recognitionStatsLog`, `enrollmentDiarizerFactory` | `knownVoicesSheet` |
| **Output** | Output Folder · Notion · Recording Retention · Meeting Notes (language, prompt, output toggles) · AI Provider · Connection Settings (endpoint, key, Advanced) | `settings` | `claudeBinaries` (#if !APPSTORE), connection-test state, `availableModels`, `hasCustomPrompt` |
| **Advanced** | Permissions · Diagnostics | — | `micPermission`, `screenRecordingOK`, `accessibilityOK` |
| **About** | Build identity · Dependencies · Updates | `settings`, `updateChecker?` | — |

**Conditional rendering rules:**
- `noMic` hides the mic-device picker (Audio) and the Speaker Identity section (Speakers)
- `diarize` hides the diarizer-mode picker and Expected Speakers stepper
- `vadEnabled` hides the VAD threshold slider
- `transcriptionEngine` switches between WhisperKit / Parakeet option panels
- `unloadModelsWhenIdle` (default on) skips the launch ASR load (a missing model is still downloaded at launch) and releases in-memory ASR and batch VAD models at a safe pipeline drain; the toggle sits beside model status and "Load Model". Turning it off restores launch preload and retains models across drains and engine switches. With the setting on, unloaded status reads "Loads when needed" while `/state` continues to report `"unloaded"`.
- `protocolProvider` switches the AI Provider section between Claude CLI / OpenAI-compatible / None; OpenAI-compatible shows the saved-connection controls (`OpenAIConnectionControls`, see `docs/architecture/pipeline.md`) and the model row there, and adds a Connection Settings section with the selected connection's endpoint, key and a collapsed Advanced group (key placement, sampling overrides; an invalid header name keeps it open, and editing a row inside it or clicking Advanced while the name is invalid latches it open, so fixing the name never closes it under the cursor). The explanations for these sections are `HelpBadge` popovers on the section headers (`SettingsHelp`), not footers, except the note that a Claude CLI API key is billed separately from the subscription, which stays in view under the key. None also hides the prompt row
- `#if APPSTORE` removes the Claude CLI provider option entirely
- `updateChecker == nil` hides the entire Updates section in About

**Cross-cutting concerns owned by sub-views:**
- `OutputSettingsView` owns OpenAI-endpoint connection testing (`testConnection()`) and custom-prompt I/O (`openCustomPrompt`, `importCustomPrompt`, reset confirmation)
- `AdvancedSettingsView` owns permission live-probing (`refreshPermissions()`)
- `AboutSettingsView` owns version/build/ffmpeg status and update-check controls

---

## Key Architectural Decisions

1. **@Observable over @StateObject** — Fine-grained reactivity, macOS 14+
2. **PipelineQueue decoupling** — Recording and post-processing run independently; WatchLoop enqueues jobs and resumes watching
3. **AudioTapLib as SPM library** — Direct in-process audio capture via CATapDescription (App Store compatible)
4. **Dual-source recording** — Enables speaker separation without diarization (app=Remote, mic=Me)
5. **Graceful degradation** — Diarization optional, continues on partial failure
6. **Pre-loaded model** — Selected engine (WhisperKit or Parakeet) loaded at app launch, prevents delay on first meeting
7. **5s cooldown** — Prevents re-detecting same meeting after handling
8. **FluidAudio on-device diarization** — Replaces Python pyannote subprocess, no external dependencies
9. **Dual-track diarization** — App and mic tracks diarized separately, avoiding echo/cross-talk interference
10. **Embedded debug RPC + automation API** — In-process HTTP server (`DebugRPCServer`) exposes state, resource metrics (`GET /metrics`), screenshot, and scene actions for shell-driven inspection and integration tests, plus a versioned `/v1` automation API (headless transcribe + job/naming control, plus idempotent `/v1/watch` and `/v1/record` control surfaces behind Stream Deck/hotkey control; reference in `docs/automation-api.md`). Off by default, opt-in via the `Settings → Advanced → Local Automation API` toggle or the `MEETINGTRANSCRIBER_DEBUG_RPC=1` env var, excluded from App Store builds via `#if !APPSTORE`. Action endpoints route through existing `Notification.Name` observers in `MeetingTranscriberApp`, so RPC-driven flows mirror real menu-bar paths.
11. **No expensive work in SwiftUI hot paths** — view bodies, computed properties read by the body, and per-render closures must not call disk I/O, JSON decode, factory constructors, regex compilation, or other non-trivial work. SwiftUI re-renders on every `@State`/`@Observable` change and fans out aggressively, so what looks cheap once becomes a CPU pin fast. Push heavy values up: store as `@State`, inject as a stored property, or surface via an `@Observable` model. Caches that mirror the underlying source (e.g. `PipelineQueue.knownSpeakerNames` mirroring the speakers DB) must wire invalidation from every mutation site in the same PR — see issue #155 → PR #158 → PR #159 for the cautionary tale.
