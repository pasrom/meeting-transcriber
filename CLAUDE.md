# Meeting Transcriber

## Project Structure

```
VERSION                    # App version (read by build scripts)
app/MeetingTranscriber/    # Swift macOS menu-bar app (SPM)
  Package.swift            # WhisperKit + FluidAudio + AudioTapLib + CLocalVQE runtime deps;
                           #   ViewInspector + SnapshotTesting test deps
  Sources/                 # @main app shell + AppState composition root wiring the concern
                           #   controllers (engines, watching, pipeline, permissions, channel
                           #   health, live transcription, RPC). ASR engines: WhisperKitEngine
                           #   (99+ langs) + ParakeetEngine (25 EU langs, via FluidAudio).
                           #   Diarization + VAD: FluidDiarizer (offline, Sortformer, Nemotron 3), FluidVAD,
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
docs/                      # architecture/ (per-area docs) + architecture-macos.md + plans/ (committed RFCs; .local/ = gitignored scratch)
protocols/                 # Protocol output dir (gitignored)
speakers.json / .env       # Runtime voice profiles + env vars (gitignored)
```

> Full per-file breakdown: `find app/MeetingTranscriber/Sources tools -name '*.swift'` — each
> file's purpose is documented in its header comment. Non-obvious design rationale and gotchas
> live in the docs listed under Architecture Docs and in Critical Notes below.

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

# Swift tests, the way CI runs them: build once, then a few long-lived xctest
# processes over whole classes (scripts/ci/test-shards.sh, which also checks that
# every listed test ran). `swift test --parallel` starts one process per test and
# is slower at this suite size: 1.5x on a 16-core machine, 5x with the three
# workers of the hosted runner; the script header has the numbers. Tests of one
# shard share a process, so a test must not assert on state only a fresh process
# has (`NSApp == nil`, say); inject that state instead, as MouseInjectionTests does.
# Never pipe a test run into `tail`/`head`/`grep` to shorten it: the shell reports
# the *last* command's status, so `... | tail -60` exits 0 on a red suite and
# the truncation hides which test failed. Redirect to a file and read that instead
# (`> /tmp/run.log 2>&1`), or enable `set -o pipefail`. Run the suite with
# CFFIXED_USER_HOME pointed at a scratch folder, or its tests write into the
# real app data under ~/Library/Application Support/MeetingTranscriber.
cd app/MeetingTranscriber && swift build --build-tests && ../../scripts/ci/test-shards.sh run --shards 3 --skip ModelPreloadTests

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

- **Conventional Commits:** `<type>(<scope>): <description>` — types: feat, fix, docs, style, refactor, perf, test, chore, build, ci, revert. CI enforces this on the PR title too (`conventional-title` check); the type list there and here must stay in step.
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

## Architecture Docs

Read the matching doc before changing or debugging that area. Each holds the area's rules, the reasoning behind them and what has been measured; much of the behaviour there looks accidental and is deliberate.

- `docs/architecture/recording.md`: capture start order, tap or microphone behaviour, restarts, device changes, silent channels
- `docs/architecture/detection.md`: meeting detectors, watched apps, browser meetings, the consent prompt
- `docs/architecture/transcription.md`: read before adding any WhisperKit call; ASR engines, WhisperKit model storage and custom models, vocabulary, live captions, VAD
- `docs/architecture/diarization.md`: diarizer modes, dual-track merging, speaker matching and voice profiles
- `docs/architecture/echo.md`: echo bleed detection, transcript dedup, embedding quarantine, LocalVQE cancellation
- `docs/architecture/pipeline.md`: `PipelineQueue` and concurrency, audio import and relocation, job restore, protocol generation, record-only mode, output folders
- `docs/architecture/permissions-lifecycle.md`: permission health checks and probes, unclean-exit detection
- `docs/architecture/debug-rpc.md`: `DebugRPCServer`, its debug endpoints and auth (the `/v1` contract is in `docs/automation-api.md`)
- `docs/architecture/gui-testing.md`: any UI change or GUI test, `A11yID`, `/ui/*` drivers, snapshots, Escape and typing injection
- `docs/architecture/diagnostics.md`: reading or adding capture log lines, triaging a silent-track report
- `docs/architecture-macos.md`: overview of source files, state machine, data flow and settings UI
- `docs/automation-api.md`: the `/v1` API reference; `docs/stream-deck.md`: Stream Deck and hotkey control

## Maintaining This File

- **Placement:** a line belongs here only if an agent working in any area needs it without being told to look. Everything else goes in that area's doc. A new area gets a doc and one router line above, naming the tasks that should trigger reading it.
- **Content:** state the current rule and why it holds, with the issue number and any measurement that backs it. Incident stories and earlier behaviour go in the issue and the commit message.
- **Upkeep:** a change that alters documented behaviour updates the doc in the same commit, rewriting or removing the old text in place. Keep each fact in one place and point to it from anywhere else.

## Cross-Cutting Rules

- Test each behaviour at the cheapest layer that can falsify it: pure logic first, then one ViewInspector wiring test per control, then live `/state`. For a GUI bug, write the failing test first at the lowest layer that reproduces it.

## Critical Notes

- AudioTapLib (CATapDescription) requires macOS 14.2+ — compiled as SPM library, no separate binary needed
- **Meeting detection** needs no Screen Recording: the watch loop auto-detects via `CompositeMeetingDetector` over `PowerAssertionDetector` (IOKit power assertions) and `MicInputDetector` (Core Audio process objects), neither of which reads window titles. The grant only sharpens the meeting *title* (`CGWindowListCopyWindowInfo`, real title vs. a placeholder) and gates the audio-tap TCC fallback below. The window-title `MeetingDetector` that would require it is not the production detector (issue #562).
- Audio capture (CATapDescription process tap) is TCC-gated: it needs either the `NSAudioCaptureUsageDescription` "Audio Recording" grant or, as a fallback, the Screen Recording grant. With neither, the tap returns `noErr` but captures silence, with no error and nothing logged (issue #524; measured on macOS 26, see the process-tap TCC-gate notes).
- FluidAudio models are downloaded automatically on first run (~50 MB); Nemotron 3 diarization mode adds a ~200 MB download the first time it is used

## E2E Architecture

Two complementary E2E approaches (fixture-based xctest `e2e.yml`, live-recording
`e2e-app.yml`/`scripts/e2e-app.sh`, and browser-meeting `e2e-browser.yml` incl. the
`--jitsi` real-meeting variant), the CI trigger labels (`run-e2e`/`run-quality`), when
to pick each, why the live-recording variant exists, and the one-time self-hosted Mac
mini runner setup → see the `e2e-architecture` skill (`.claude/skills/e2e-architecture/`).
Read it before touching the E2E workflows, `scripts/e2e-app.sh`, `scripts/e2e-browser.sh`,
the naming-confirm lane, or runner configuration.

## Build Variants

Two build variants controlled by compile-time flag `APPSTORE` (`-Xswiftc -DAPPSTORE`):

| | Homebrew | App Store |
|---|---|---|
| **Claude CLI** | Yes (Process subprocess) | No (sandbox forbids Process) |
| **OpenAI API** | Yes | Yes (only LLM option) |
| **Debug RPC server** | Yes (env-gated) | No (`#if !APPSTORE`) |
| **Safari call audio** | Yes (`ProcessResponsibility` via `dlsym`) | No (private symbol unavailable; bundle-derived PIDs only) |
| **Chromium helper selection** | Yes (`ChromiumHelperFilter` reads argv via `KERN_PROCARGS2`) | Not measured: if the sandbox refuses the sysctl for other processes, every argv reads empty and the tap keeps all helpers (the issue #791 stall); the refusal is logged with its errno |
| **Entitlements** | Mic only | Sandbox + mic + network + file picker |
| **Build** | `./scripts/build_release.sh` | `./scripts/build_release.sh --appstore` |
| **Tests** | ~4,100 | ~3,600 (CLI + RPC tests excluded via `#if !APPSTORE`) |

- CLI-specific code lives in `ClaudeCLIProtocolGenerator.swift` and `DebugRPCServer.swift` (each entire file `#if !APPSTORE`)
- `ProtocolProvider` enum uses `CaseIterable` — `.claudeCLI` case excluded at compile time, picker adapts automatically
- `ProtocolError` has `#if !APPSTORE` around CLI error cases (enum cases cannot be added via extension)
- FFmpegHelper also uses `Process()` but falls back gracefully to `nil` — no `#if` needed
