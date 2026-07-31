# Meeting Transcriber

## Project Structure

```
VERSION                    # App version (read by build scripts)
app/MeetingTranscriber/    # Swift macOS menu-bar app (SPM)
  Package.swift            # WhisperKit + FluidAudio + AudioTapLib runtime deps;
                           #   ViewInspector + SnapshotTesting test deps
  Sources/                 # @main app shell + AppState composition root wiring the concern
                           #   controllers (engines, watching, pipeline, permissions, channel
                           #   health, live transcription, RPC). ASR engines: WhisperKitEngine
                           #   (99+ langs) + ParakeetEngine (25 EU langs, via FluidAudio).
                           #   Diarization + VAD: FluidDiarizer (offline + Sortformer), FluidVAD,
                           #   SpeakerMatcher. Recording: DualSourceRecorder (app audio + mic).
                           #   Post-processing: PipelineQueue (transcribe -> diarize -> protocol).
                           #   Live captions overlay + StreamingTranscriber. Settings UI
                           #   (SettingsView + Settings/). Protocol generation:
                           #   ClaudeCLIProtocolGenerator (#if !APPSTORE) / OpenAIProtocolGenerator.
                           #   DebugRPCServer + /v1 automation API (#if !APPSTORE).
  Tests/                   # XCTest + ViewInspector; Fixtures/ test audio (two_speakers_de.wav, ...)
  Entitlements/            # Homebrew.entitlements (mic only) + AppStore.entitlements (sandbox)
  Info.plist               # Bundle metadata
tools/audiotap/            # AudioTapLib: CATapDescription app-audio + AVAudioEngine mic capture (SPM lib)
tools/meeting-simulator/   # Meeting simulator for testing
tools/mt-cli/              # Thin Swift client for DebugRPCServer (+ skill.md)
scripts/                   # build_release / run_app / e2e-*.sh drivers, lint.sh, pre-push.sh,
                           #   test-audio + quality-fixture generators, self-hosted runner setup
Casks/                     # Homebrew Cask formulae (meeting-transcriber + @beta)
.github/workflows/         # CI (lint/analyze/test), release, e2e lanes, quality-and-safety, pages
docs/                      # architecture-macos.md + plans/ (committed RFCs; .local/ = gitignored scratch)
protocols/                 # Protocol output dir (gitignored)
speakers.json / .env       # Runtime voice profiles + env vars (gitignored)
```

> Full per-file breakdown: `find app/MeetingTranscriber/Sources tools -name '*.swift'` — each
> file's purpose is documented in its header comment. Non-obvious design rationale and gotchas
> live in the Architecture Notes and Critical Notes sections below.

## Pipeline

```
Dual-source: AudioTapLib (CATapDescription + AVAudioEngine) → separate 16kHz audio → [WhisperKit | Parakeet] per track → FluidAudio diarization per track (CoreML/ANE) → merge speakers → Claude CLI / OpenAI-compatible API → Markdown protocol
Single-source: Audio/Video → 16kHz mono (AVAudioFile → AVAsset → ffmpeg fallback) → [WhisperKit | Parakeet] → FluidAudio diarization → Claude CLI / OpenAI-compatible API → Markdown protocol
```

## Setup

```bash
# Run menu bar app (builds automatically, including AudioTapLib):
./scripts/run_app.sh
```

## Key Commands

```bash
# Run menu bar app
./scripts/run_app.sh

# Swift tests (parallel — ~1.4× faster than sequential)
cd app/MeetingTranscriber && swift test --parallel

# Swift tests under sanitizers (slow — TSan ~7.5 min, ASan ~4.5 min on M-series)
# CI runs these nightly via cron + on push to main; locally use ad-hoc
# before pushing concurrency-heavy or C-bridging changes.
cd app/MeetingTranscriber && swift test --parallel --sanitize=thread --skip MenuBarIconSnapshotTests
cd app/MeetingTranscriber && swift test --parallel --sanitize=address --skip MenuBarIconSnapshotTests

# Trigger sanitizer matrix on a specific PR/branch via CI
gh workflow run quality-and-safety.yml -f run-sanitizer=true -f run-quality=false

# Lint & format check (dry-run, no changes)
./scripts/lint.sh

# Lint & format auto-fix (SwiftFormat + SwiftLint --fix)
./scripts/lint.sh --fix

# Pre-push parity check (release build — catches Sendable diagnostics
# that debug-mode tolerates; flags App Store variant when --with-appstore)
./scripts/pre-push.sh

# Build self-contained .app + DMG for distribution (Homebrew)
./scripts/build_release.sh

# Run app with debug RPC server enabled (dev-only; binds 127.0.0.1:9876)
MEETINGTRANSCRIBER_DEBUG_RPC=1 ./scripts/run_app.sh

# Build mt-cli (talks to the running RPC server)
cd tools/mt-cli && swift build && .build/debug/mt-cli state

# Live smoketest of the RPC server (kills + builds + launches + asserts)
./scripts/test_rpc.sh

# Build App Store variant (sandbox, no Claude CLI)
./scripts/build_release.sh --appstore --no-notarize
```

## Distribution

Homebrew Cask distribution (stable vs `@beta`), the `v*` tag release workflow, and
the stable-tag ruleset gate → see the `distribution` skill (`.claude/skills/distribution/`).

## Git Workflow

Use the `/git-workflow` skill. Commit proactively after every logical unit of work — don't wait for user permission.

- **Conventional Commits:** `<type>(<scope>): <description>` — types: feat, fix, docs, refactor, test, perf, chore, build
- **Scopes:** app, test, build, ci, docs
- **Atomic commits:** one logical change per commit. If you need "and" in the message, split it.
- **Stage explicitly:** `git add <file1> <file2>` — never `git add -A` or `git add .`
- **Verify first:** run tests before committing
- **Commit body:** document the WHY for non-trivial changes (architecture decisions, rejected alternatives)
- **Never push to main directly.** Always create a branch, open a PR, and merge via `gh pr merge --rebase --delete-branch`. Only exception: version bumps in `VERSION` file.
- **Rebase merge only.** Squash and merge commits are disabled by repo policy.

## Conventions

- All code and UI text in English
- Protocol output language configurable via `AppSettings.protocolLanguage` (default: German)
- **Plan files:**
  - `docs/plans/` (committed) — RFCs and reference docs for future features that should be visible to anyone reading the repo
  - `docs/plans/.local/` (gitignored) — personal scratch; optional subfolders `open/`, `research/`, `done/`, `future/`, `deferred/`
  - Default to `.local/` for ad-hoc notes, diagnostic dumps, and active finding-trackers; promote to committed `docs/plans/` only when the plan is shared reference material
  - **Never reference `.local/` content in shared artifacts** (PR descriptions, commit messages, code comments, in-app UI, GitHub issues): no file paths under `.local/`, no internal task identifiers like P4/P6/B22/H1/L6, no internal PR-internal nicknames. Reviewers don't see those. Inline the relevant content instead, or describe in plain language. The same applies to chat replies framed as PR/commit-ready text.

## Architecture Notes

**Transcription engines:**
- `TranscribingEngine` protocol abstracts ASR backends. Two implementations: `WhisperKitEngine` (99+ languages, ~1 GB model) and `ParakeetEngine` (25 EU languages, ~50 MB model, ~10× faster).
- `AppSettings.transcriptionEngine` enum (`.whisperKit` / `.parakeet`) selects the engine. Settings UI shows engine picker; engine-specific options hidden when not selected. `availableCases` (filtered by `isAvailable`) is the picker source — a capability hook kept for engines with stricter OS floors.
- Parakeet auto-detects language (no parameter) and supports custom vocabulary via CTC boosting (`ParakeetEngine.customVocabularyPath`). WhisperKit supports explicit language selection.
- `EngineController` (`@MainActor`) owns the engine instances + the active-engine selection (`activeTranscriptionEngine`, used by `PipelineQueue`) + the settings → engine language/vocabulary sync (up-front + reactive) + launch model preload. `AppState` exposes it as `engines`.

**Live captions (PoC):** "Show partial transcripts during recording" in Settings → Transcribe (`AppSettings.liveTranscriptionEnabled`, off by default; enabling downloads a ~0.6 GB model on first use behind a consent alert).
- `LiveCaptionsGate.strategy(liveEnabled:engineLanguage:engineSupportsLive:)` is the pure decision function (shared by `AppState`, `LiveTranscriptionCoordinator`, `LiveTranscriptionController`) that routes each channel by the active engine's **explicitly configured** language: `en` → `EouStreamingCaptionSession` (FluidAudio Parakeet EOU), any other explicit language → `NemotronStreamingCaptionSession`/`NemotronAsrManager` (FluidAudio Nemotron multilingual), auto-detect → re-transcribe via `StreamingTranscriber` if the engine supports it, else off.
- Both streaming backends are engine-independent (drive their own FluidAudio models directly), so captions work even when the active `TranscribingEngine` has no live re-transcribe hook. `LiveTranscriptionController` wires the resolved per-channel pipeline to both `DualSourceRecorder` sinks and feeds `LiveCaptionsState`, which backs the `LiveCaptionsOverlay` window. `ModelWarmupQueue` serializes model warm-up loads so the ASR engine and streaming models don't compile/load concurrently at launch.

**Concurrency:**
- `WatchLoop` is `@MainActor`. Tests for this class must also be `@MainActor`.
- Both engine `loadModel()` methods deduplicate concurrent calls via `loadingTask` — second caller awaits the first's task. Safe to call from multiple places.
- `ClaudeCLIProtocolGenerator` uses async process I/O: the process `terminationHandler` yields into an `AsyncStream<Void>` that the caller awaits, instead of blocking on `process.waitUntilExit()`. The stream is installed before `process.run()` and buffers the yield, so an early exit is never missed. stdin/stdout are written/read in detached `Task`s.

**View architecture:**
- `SettingsView` receives its dependencies as stored properties (not `@State`): the engine instances, `updateChecker`, `recognitionStatsLog`, an `enrollmentDiarizerFactory`, the `namingDialogActive`/`pipelineBusy` state flags, and an `onSpeakerMutate` callback.

**Audio loading:**
- `AudioMixer.loadAudioAsFloat32()` uses a 3-tier fallback: `AVAudioFile` → `AVAsset` → `FFmpegHelper` (ffmpeg CLI).
- `loadAudioFromAVAsset()` extracts audio tracks via `AVAssetReader`, outputs 16kHz Float32 PCM.
- `FFmpegHelper` detects ffmpeg binary (env var → `/opt/homebrew/bin` → `/usr/local/bin` → `~/.local/bin` → `/usr/bin`), cached via static let. Converts to 16kHz mono WAV via temp file.
- Both `NSOpenPanel` type lists (batch import + voice enrollment) come from `AudioImportTypes`, not inline literals — the panels are manual-QA-only, so the pure type list is what tests can pin. Only MKV/WebM are ffmpeg-gated; AMR, 3GPP and Ogg (`.opus`/`.ogg`) decode natively and must stay out of `FFmpegHelper.ffmpegOnlyExtensions`, whose members skip `AVAudioFile`/`AVAsset` entirely.
- ffmpeg is optional — install via `brew install ffmpeg`. Status shown in Settings → About.
- **A finished job only relocates audio the app itself produced.** `AudioPersistencePolicy` decides per file: sources inside the staging dir (`AppPaths.recordingsDir`, where `DualSourceRecorder` writes) move into `<outputDir>/recordings`, sources already there stay put (moving would rename them under a fresh stamp and orphan recovery would re-pick them forever), and anything else is a user-picked import that is left untouched. Persisting an import would duplicate a file the user already has for no consumer: re-diarization and late naming read the `_16k.wav` sidecar, while orphan recovery and `ProcessedRecordingsLedger` only scan the staging dir. Consequence to keep in mind: a finished import leaves **no audio at all** in the output folder, only the transcript and the protocol. The 16 kHz sidecars live there while speaker naming is outstanding and `removeNamingData` deletes them once it resolves, so what used to remain for an import was exactly the relocated original. The source staying in the user's folder is now the archive.

**Recording:**
- `DualSourceRecorder` uses `AudioTapLib.AudioCaptureSession` directly (no subprocess). App imports the library via SPM local package dependency.
- `DualSourceRecorder` captures `recordingStartTime` in `start()`, not in `stop()`.
- Grace period minimum is 1 second (enforced in `AppSettings.endGrace` setter).

**Detection:**
- `MeetingDetecting` protocol abstracts detection strategies. Two implementations: `MeetingDetector` (window title matching via `CGWindowListCopyWindowInfo`) and `PowerAssertionDetector` (IOKit power assertions — sandbox-safe, no Screen Recording permission needed).
- `MeetingDetector` counts each pattern once per poll — prevents over-counting when multiple windows match the same app.
- **Browser meetings (issue #503):** `PowerAssertionDetector` also carries a `Google Chrome` pattern that matches the `NoIdleSleepAssertion` named `"WebRTC has active PeerConnections"` (keyword `webrtc`/`peerconnection`, not the assertion type — Chrome holds the same type for plain media playback), so Google Meet / Whereby / web Zoom-Teams-Webex are detected without window titles. It is opt-in via `AppSettings.watchBrowserMeetings` (default off, appends `"Google Chrome"` to `watchApps`). Because the WebRTC signal isn't meeting-exclusive, browser meetings are gated behind a consent prompt (`AppMeetingPattern.requiresRecordingConsent` → `WatchLoop.requestConsentIfNeeded` → `NotificationManager.askToRecord`, a `BROWSER_MEETING_CONSENT` notification with Record/Ignore actions) instead of auto-starting; a decline suppresses re-prompts for a cooldown (`BrowserConsentPolicy`), and an explicit refusal and an unanswered prompt are told apart: ten minutes of quiet after a no, one after silence, because silence means the user was away rather than opposed (`ConsentAnswer`). **The prompt is awaited off the poll loop** (`WatchLoop+Consent.swift`): an open question parks in `pendingConsentApp` (also on `/state`) and an answer parks in `approvedConsentMeeting` for the loop to start, so detection keeps running meanwhile. It used to be awaited inline, which stopped `checkOnce()` for up to `consentPromptTimeout` and lost native meetings starting in that window. That is also why the prompt now stays open five minutes rather than one: it blocks nothing, and a minute only ever suited someone sitting at the screen. Accepted and not fixable without a distinguishing signal: Google Meet holds the same assertion on a page you cannot join ("You can't join this video call"), so a stale link parks a prompt about no meeting at all; a title filter would be language-dependent, and the cost is now one prompt rather than a minute of blindness. Audio capture reuses the existing multi-PID tap (Chrome is multi-process like Electron); capturing only the meeting tab vs. all Chrome audio is a known follow-up.
- **The consent prompt makes notification permission a hard dependency of browser meetings.** Denied (or provisional-only) notifications mean the prompt is never seen, times out as a decline, and nothing is ever recorded while the toggle still reads as on. `BrowserConsentReadiness` decides when Settings → General warns about that; the warning lives there and not in `PermissionHealthCheck` because reporting a broken notification channel *by notification* cannot work, and because the permission only matters for this one opt-in feature. Authorisation is not the whole question: an authorised app whose alert style is None, or whose Time Sensitive switch is off, also never shows the prompt, so `PermissionsController.notificationVisibility` polls the whole `NotificationVisibility` (authorisation + alert setting + alert style + time-sensitive + scheduled delivery) alongside the TCC probe, `/state.permissionHealth.notifications*` exposes it, and `scripts/e2e-browser.sh` asserts on it — that lane answers consent over RPC and would otherwise pass on a runner where a real user would see nothing.

**Diarization:**
- `FluidDiarizer` uses FluidAudio (CoreML/ANE) for on-device speaker diarization — no HuggingFace token needed. Two modes: `.offline` (default) and `.sortformer` (overlap-aware, via `SortformerDiarizer`). Selected via `AppSettings.diarizerMode`.
- **Dual-track diarization:** App and mic tracks are diarized separately. Speaker IDs are prefixed (`R_` for remote/app, `M_` for mic/local), merged, and assigned via `assignSpeakersDualTrack`. Single-source recordings fall back to diarizing the mix with `assignSpeakers`.
- **Sortformer post-hoc embeddings:** `FluidDiarizer+SortformerEmbeddings.swift` extracts per-speaker WeSpeaker embeddings after Sortformer diarization (DiariZen-style hybrid), using overlap-excluded masks so mixed-speaker frames don't contaminate centroids. Enables `SpeakerMatcher` recognition when using the Sortformer mode.
- `SpeakerMatcher` stores speakers in `speakers.json` with a running-mean **centroid** (primary anchor) plus a recent-samples FIFO (max 3, fallback when centroid match is borderline). Quality filter: embeddings from segments shorter than `minSpeakingTimeForCentroid` (3 s) are kept as fallback samples but excluded from the centroid. Threshold 0.40, confidence margin 0.10. Legacy entries without a persisted centroid compute `meanEmbedding(embeddings)` lazily until the next confirmation seeds a real centroid.
- **Live speaker matching:** `LiveSpeakerMatcher` (actor) matches finalized live-caption utterances against `speakers.json` in real time using the same WeSpeaker CoreML model as the batch pipeline — voices enrolled post-meeting are recognised in subsequent live sessions without re-enrollment. Cold-start optimisation: caches the WeSpeaker mask frame count in `UserDefaults` so only the embedding model is loaded on subsequent launches.
- **Experimental diarization tuning:** `AppSettings` exposes five `OfflineDiarizerConfig` knobs (`clusterThreshold`, `warmStartFa`, `warmStartFb`, `minSegmentDurationSeconds`, `excludeOverlap`) editable via Settings → Speakers → Experimental Diarization Tuning. All default to FluidAudio community values; a reset button restores defaults.
- `DiarizationProvider` protocol enables mock injection in tests.

**VAD preprocessing:**
- `FluidVAD` wraps FluidAudio Silero v6 for voice activity detection. When enabled (`AppSettings.vadEnabled`), silence is trimmed before transcription and timestamps are remapped back to the original timeline via `VadSegmentMap`.
- `PipelineQueue` holds a cached `FluidVAD` instance (reused across jobs). Pass `vadConfig: nil` to disable.

**Protocol generation:**
- `ProtocolGenerating` protocol with two implementations: `ClaudeCLIProtocolGenerator` and `OpenAIProtocolGenerator`.
- `AppSettings.protocolProvider` enum (`.claudeCLI` / `.openAICompatible` / `.none`) selects the provider. `.none` skips LLM generation and saves the transcript only.
- `AppSettings.protocolLanguage` string (default `"German"`) is substituted into the prompt as `{LANGUAGE}`.
- `ProtocolGenerator.loadPrompt()` loads custom prompt from `AppPaths.customPromptFile` (`~/Library/Application Support/MeetingTranscriber/protocol_prompt.md`), falls back to built-in default.
- `OpenAIProtocolGenerator` supports any OpenAI-compatible HTTP API (Ollama, LM Studio, llama.cpp, etc.).

**UI:**
- `MenuBarIcon` renders animated waveform reflecting pipeline state (idle, recording, transcribing, diarizing, protocol).
- `AppPickerView` enables manual recording of any app via app picker.
- `UpdateChecker` checks GitHub releases for newer versions, shows badge on menu bar icon.

**Permission health check:**
- `PermissionHealthCheck` verifies each TCC permission by combining the system verdict with a live probe. Each resolves to `PermissionStatus` (`.healthy | .denied | .broken | .notDetermined`). `.broken` means TCC says allowed but the probe disagrees — fix is to toggle the permission off and on in System Settings.
- `WatchLoop` runs the check on startup; `AppState` re-runs on app activation.
- When unhealthy: `MenuBarIcon` composites a red "!" badge over the current icon (non-template, stays red in dark mode). `BadgeKind.compute()` returns `.error` when idle with a problem. A deduped notification is posted via `NotificationManager`.

**Debug RPC server (dev-only):**
- `DebugRPCServer` is an embedded HTTP server bound to `127.0.0.1:9876` that exposes app state, screenshots, and scene actions for shell-driven inspection. Whole file is `#if !APPSTORE`. Two enable paths: persistent `Settings → Advanced → Local Automation API` toggle (key `debugRPCEnabled`, off by default), or per-session `MEETINGTRANSCRIBER_DEBUG_RPC=1` env var (force-starts at launch). `AppState.applyDebugRPCSetting()` reconciles the running server with both signals at startup and on toggle changes.
- Debug / inspection endpoints (no stability contract): `GET /state` (pipeline + speaker DB + engine state JSON; `engines.*.modelState` lets driver scripts wait for model preload), `GET /healthz`, `GET /metrics` (cumulative CPU/RAM/instructions self-report via `proc_pid_rusage` — diff two snapshots for window averages; process-only, child processes excluded; consumed by `scripts/e2e-cpu-load.sh`), `GET /screenshot` (PNG of the largest visible window), `GET /ui/tree` (read-only accessibility tree of an allowlisted window as JSON — `?window=settings` by default; walks the app's own self-pid `AXUIElement` tree in-process — which surfaces SwiftUI's `.accessibilityIdentifier`s, unlike the `NSView.accessibilityChildren()` walk — and needs no Accessibility TCC grant since self-inspection is exempt; lets a driver assert on UI structure instead of pixel-diffing a screenshot; PII windows stay off the allowlist), `POST /action/confirmBrowserConsent` (resolve a parked browser-meeting consent prompt without a clickable notification, issue #503; body `{granted:bool}` → `{"resolved":true}` if a prompt was waiting, `{"resolved":false}` no-op otherwise; resolves inline via the lock-guarded `ConsentPromptCoordinator`, no main-actor hop — used by `scripts/e2e-browser.sh` via `mt-cli confirm-browser-consent`), `POST /ui/press` (drive a real UI action: presses the control with the given accessibility `identifier` in an allowlisted window via in-process `AXUIElementPerformAction(kAXPressAction)` on the self-pid tree — no TCC grant, runs on the main actor; body `{window, identifier}`; the pressable set is a reviewed per-identifier allowlist, not "any control in the window", so a token-holder can't trigger arbitrary or modal-opening controls; 200 `{"dispatched":<bool>}` (named for dispatch, not effect — the flag is true whenever the actuation ran, so assert `/state`) / 404 allowlisted id absent from tree / 409 present-but-disabled / 403 disallowed window or identifier / 503 window not open; the driver asserts the resulting state via `GET /state`, not the returned flag), `POST /action/openSettings`, `POST /action/closeSettings`.
- Versioned automation API under `/v1` (carries a stability contract, kept off the debug `/action/*` surface): `POST /v1/transcribe` (blocking one-call: 200 terminal / 202 still-running / 400), `POST /v1/jobs` + `GET /v1/jobs/<id>` (enqueue + poll), `GET`/`POST /v1/jobs/<id>/naming` + `POST /v1/jobs/<id>/naming/skip` (speaker naming; 409 on wrong state, 404 unknown id). The two POST enqueue routes honour an `Idempotency-Key` header. Finished-job readback survives the 60s queue reaping + an app restart via `TerminalJobStore`. Full reference: `docs/automation-api.md`. Routing in `DebugRPCServer+V1.swift`.
- Two-layer auth: 32-byte hex bearer token at `~/Library/Application Support/MeetingTranscriber/.rpc-token` (chmod 0600) + reject on any non-empty browser `Origin` header.
- Action endpoints post `Notification.Name.showSettings` / `.closeSettings` that the `@main` scene observes and routes to `bringWindowToFront(id: "settings")` / `closeWindow(id: "settings")` — same path the menu bar uses.
- `tools/mt-cli` is the matching CLI client; `scripts/test_rpc.sh` is a live end-to-end smoketest. In-process integration tests live in `Tests/DebugRPCServerIntegrationTests.swift` (real sockets via OS-assigned port exposed through `DebugRPCServer.boundPort`).

**Record-only mode:**
- When `AppSettings.recordOnly` is true, `WatchLoop.enqueueRecording()` moves the dual-source WAVs into `<settings.effectiveOutputDir>/recordings/` and writes a `<basename>_meta.json` `RecordingSidecar` next to them, skipping the entire post-processing pipeline (VAD, transcription, diarization, protocol generation). Both call sites — auto-detected meetings (`handleMeeting`) and manual recordings (`stopManualRecording`) — flow through the same branch. The destination is wrapped in `startAccessingSecurityScopedResource()` to honour user-picked Output Folder bookmarks (relevant for the App Store sandboxed build).
- Sidecar JSON contains: `version` (currently `RecordingSidecar.currentVersion = 2`), `title`, `appName`, `startedAt`/`stoppedAt` (ISO 8601, reconstructed from `recordingStart` uptime), `participants`, `micDelaySeconds`, `trigger`, `files` (basenames only). Optional `app` / `mic` filenames are omitted when nil.
Suffix constants live as static lets: the audio-file suffixes on `RecordingFileSuffix` (`mix = "_mix.wav"`, `app`, `mic`, and the raw-temp `appRaw`/`legacyAppRaw`), and the sidecar suffix on `RecordingSidecar.filenameSuffix = "_meta.json"`.
- `trigger` (`auto` | `manual`, added in version 2) says which call site produced the recording, so a fleet consumer can discard a very short *auto* capture as a false trigger while always processing an equally short *manual* one — duration alone cannot tell those apart. A browser meeting is `auto`: the detector initiates it and the consent prompt only gates it. Every field added after version 1 must decode as optional, because `RecordingSidecar.read` is a `try?` and one unrecognised value would otherwise discard the *entire* sidecar on the reimport path.
- Intended for fleet topologies where macOS clients capture and a separate machine (e.g. Linux GPU host) processes the audio via Syncthing or similar.
- Menu bar: the small red dot is rendered as a **persistent overlay** (`MenuBarIcon.image(..., recordOnlyOverlay:)`) on top of *whatever* primary badge `BadgeKind.compute(...)` would otherwise show — idle, recording, transcribing, etc. — so the mode is always visible. Permission overlay (red exclamation) takes precedence when both apply, since a permission problem actually breaks recording. Settings tabs dim Transcription / Protocol / VAD / Diarization sections via `View.recordOnlyDisabled(_:)` and show a banner in the General tab pointing at the active output dir.
- Sidecar write failures notify the user via `NotificationManager` (injected as `any AppNotifying` on `WatchLoop`) since record-only does not transition state to `.error`.

## Critical Notes

- AudioTapLib (CATapDescription) requires macOS 14.2+ — compiled as SPM library, no separate binary needed
- Screen Recording permission required for **meeting detection** (window titles via `CGWindowListCopyWindowInfo`)
- Audio capture (AudioTapLib) does NOT require Screen Recording — uses CATapDescription (purple dot indicator)
- FluidAudio models are downloaded automatically on first run (~50 MB)

## GUI Testing

Rule: test each behavior at the cheapest layer that can falsify it.

1. **Pure logic first.** Extract decision logic into a value type
   (`BadgeKind.compute`, `LiveCaptionsGate`, `WatchLoopEndPolicy` pattern) and put
   the bulk of assertions there.
2. **ViewInspector** (`swift test`, every PR): exactly one wiring test per control —
   find by its `A11yID` constant (or by label, for `Picker`/`Stepper`, which expose
   no findable one — see Identifiers), drive (`.tap()`/`.select()`/`.increment()`),
   assert the `AppSettings` write-back. Don't enumerate logic states through the view;
   that's layer 1's job. (ViewInspector is reflection over undocumented SwiftUI
   internals — keep to the boring primitives; breakage is loud since it runs on
   every PR.)
3. **`/state` (live RPC):** first choice for live assertions, including window/scene
   behavior via `/state.windows` (`isVisible` after deactivate, `floating`,
   `canJoinAllSpaces` — how #509/#511 guard the naming-window pin).
4. **`/ui/tree` + `/ui/press` + `/ui/type`** (live, Settings window only): only for behavior that
   exists solely in the real AppKit/AX layer. A live test earns its keep only when
   ViewInspector cannot instantiate the failing layer (real NSWindow/NSPanel,
   focus/activation, scene routing, the NSHostingView boundary, actual AX exposure).
5. **Snapshots** (dev-only, `XCTSkipIf(isCI)`): pixel truth; never CI-gated.

**Identifiers:** add `.accessibilityIdentifier` on demand via the shared `A11yID`
namespace (`Sources/A11yID.swift`) — the view modifier, the ViewInspector `find`, and
the `/ui/press` allowlist all reference the constant so the compiler catches drift.
Interaction tests locate by the `A11yID` constant wherever a control exposes a
findable one. Accepted exception: SwiftUI `Picker` and `Stepper` don't surface a
ViewInspector-findable `.accessibilityIdentifier`, so those are located by label or
document-order index (see `SettingsInteractionTests`) — the one sanctioned fallback,
not a licence to skip identifiers where they work. `find(text:)` for a bare label
only when the label itself is the behavior under test. An identifier makes a control
tree-visible;
press-drivable *additionally* requires a `/ui/press` allowlist entry — never allowlist
a control whose action opens a menu/popover/sheet/panel (a nested runloop wedges the
app, see `DebugRPCServer+UIPress.swift`). Never widen the window allowlist to PII
windows or expose control values (`DebugRPCServer+UITree.swift`).

**Live assertions:** assert the `/state` effect, never the returned `pressed` flag or
tree structure (depth/frames/child counts). Assert the env-stable, load-bearing pin
subset (`isVisible`, `floating`, `canJoinAllSpaces`) — `fullScreenAuxiliary` proved
env-unstable on the CI mini (#511). `e2e-ui-smoke` is a harness-liveness canary only —
feature-level live assertions go in `test_rpc.sh` or the `e2e-app` lanes.

**GUI bug found:** failing test first, at the lowest layer that reproduces it. If only
the live scene reproduces, drive the real scene window (a minimal probe window does not
reproduce — #504). Acceptance: revert the fix, test goes red.

**Don't:** chase snapshot coverage; use `/ui/press` to arrange state (it's for testing
the pressed control); test SwiftUI framework behavior (e.g. that `.keyboardShortcut`
fires). **Manual-QA-only, accepted:** menu-bar dropdown interaction, modal panels
(NSOpenPanel/NSAlert), TCC prompts, drag/focus order, visual appearance beyond dev-only
snapshots.

**Typing** is automatable via `POST /ui/type` (allowlisted plain text fields only —
never a `SecureField`). It posts real key events, because an AX set-value does *not*
fire the SwiftUI binding; that asymmetry is why there is no `/ui/setValue`. Pass
`clear: true` to replace rather than append, or the assertion depends on the field's
prior contents. Reaching a control outside the General tab needs a tab switch first,
and only `POST /ui/press` with `"via": "click"` performs one — the AX press reports
success on a sidebar row without selecting it.

## E2E Architecture

Two complementary E2E approaches (fixture-based xctest `e2e.yml`, live-recording
`e2e-app.yml`/`scripts/e2e-app.sh`, and browser-meeting `e2e-browser.yml` incl. the
`--jitsi` real-meeting variant), the CI trigger labels (`run-e2e`/`run-quality`), when
to pick each, why the live-recording variant exists, and the one-time self-hosted Mac
mini runner setup → see the `e2e-architecture` skill (`.claude/skills/e2e-architecture/`).
Read it before touching the E2E workflows, `scripts/e2e-app.sh`, `scripts/e2e-browser.sh`,
the naming-confirm lane, or runner configuration.

## Diagnostics

`AppSettings.audioDebugLogging` (Settings → Diagnostics → "Verbose Audio Logging") enables forensic logging in the audio-capture path:

- `[debug] Tap target: pid=… exe=… bundle=… audioObjectID=…` at start
- `[debug] Default output device: name=… uid=… transport=… rate=…` at start and on device change
- `[debug] Tap format: rate=… Hz, tapID=…` after tap is configured
- `[debug] Output device change → name=… uid=…` when system output device changes mid-capture
- `[debug] App audio RMS (5s): … dBFS, samples=…, totalBytes=…` every 5 s during capture — live signal whether the tap is delivering real audio or zero/noise
- `[debug] App audio capture stopping: totalBytes=…` at stop
- `[debug] Mic input device: name=… uid=… hwRate=… hwChannels=…` at mic capture start
- `[debug] Mic RMS (5s): … dBFS, samples=…` every 5 s during mic capture

View via Console.app, subsystem `com.meetingtranscriber.audiotap`. Off by default; turn on when investigating silent recordings or unusual routing.

## Build Variants

Two build variants controlled by compile-time flag `APPSTORE` (`-Xswiftc -DAPPSTORE`):

| | Homebrew | App Store |
|---|---|---|
| **Claude CLI** | Yes (Process subprocess) | No (sandbox forbids Process) |
| **OpenAI API** | Yes | Yes (only LLM option) |
| **Debug RPC server** | Yes (env-gated) | No (`#if !APPSTORE`) |
| **Entitlements** | Mic only | Sandbox + mic + network + file picker |
| **Build** | `./scripts/build_release.sh` | `./scripts/build_release.sh --appstore` |
| **Tests** | ~1,900 | fewer (CLI + RPC tests excluded via `#if !APPSTORE`) |

- CLI-specific code lives in `ClaudeCLIProtocolGenerator.swift` and `DebugRPCServer.swift` (each entire file `#if !APPSTORE`)
- `ProtocolProvider` enum uses `CaseIterable` — `.claudeCLI` case excluded at compile time, picker adapts automatically
- `ProtocolError` has `#if !APPSTORE` around CLI error cases (enum cases cannot be added via extension)
- FFmpegHelper also uses `Process()` but falls back gracefully to `nil` — no `#if` needed
