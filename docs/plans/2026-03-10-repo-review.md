> **Note (2026-03-18):** This review predates the migration from WhisperKit to FluidAudio Parakeet TDT for transcription. References to `WhisperKitEngine` now correspond to `FluidTranscriptionEngine`.

# Full Repository Review — Results

> **For Claude:** This document contains the complete review findings from 7 parallel agents.
> To implement fixes, use superpowers:writing-plans to create a fix plan from the prioritized findings below.

**Date:** 2026-03-10
**Test count:** 341 tests, 0 failures
**Coverage:** 58.7% lines (90%+ on testable business logic)

---

## Priority 1: Critical (Bugs, Security, Crash-Risiken)

### C1. Speaker naming continuation never resumed → pipeline hangs forever
- **File:** `app/MeetingTranscriber/Sources/PipelineQueue.swift`, lines 57-61, 325
- **Problem:** If the speaker naming window is dismissed without calling `completeSpeakerNaming`, the `withCheckedContinuation` at line 325 is never resumed. The pipeline job hangs in `.diarizing` state indefinitely. No timeout or cancellation path exists.
- **Fix:** Add a timeout around the continuation, or ensure `onDisappear` always calls `completeSpeakerNaming(result: .skipped)`. Use `withCheckedThrowingContinuation` and cancel if job is cancelled.

### C2. Stale index after `await` in `processNext()` — potential crash
- **File:** `app/MeetingTranscriber/Sources/PipelineQueue.swift`, lines 171-301
- **Problem:** `index` is captured for the `.waiting` job at line 171. After multiple `await` points (diarization calls), if any job is removed by the auto-removal timer, `index` could point to the wrong job or be out of bounds. The `participants` access on line 301 is the most concerning.
- **Fix:** Copy all needed fields from `jobs[index]` into local variables before the first `await`, or use `jobs.first(where: { $0.id == jobID })` after await points.

### C3. `onDisappear` can double-resume continuation → crash
- **File:** `app/MeetingTranscriber/Sources/SpeakerNamingView.swift`, lines 151-156
- **Problem:** SwiftUI can call `onDisappear` before the Button action completes. If `onDisappear` fires before `completed = true` in the confirm button action, it sends `.skipped`, then the button action sends `.confirmed` — double-resuming `speakerNamingContinuation` crashes.
- **Fix:** Use a single synchronized method for completion delivery, or have the parent close the window and remove the `onDisappear` fallback. Alternatively, use `@State private var result: SpeakerNamingResult?` and deliver only once.

### C4. Race condition in `loadModel()` — TOCTOU on `loadingTask`
- **File:** `app/MeetingTranscriber/Sources/WhisperKitEngine.swift`, lines 43-83
- **Problem:** `WhisperKitEngine` is `@Observable` but not `@MainActor`. The `loadingTask` check-and-set is not atomic. Two concurrent callers can both pass `if let existing = loadingTask` before either sets it, leading to two simultaneous loads.
- **Fix:** Add `@MainActor` to `WhisperKitEngine` (all callers are already `@MainActor`).

### C5. `terminationHandler` set after process exit → permanent hang
- **File:** `app/MeetingTranscriber/Sources/ProtocolGenerator.swift`, lines 148-152
- **Problem:** `readStreamJSON` blocks until stdout EOF (line 140). By the time `withCheckedContinuation` sets `terminationHandler` at line 149, the process may have already exited. If `Process` doesn't retroactively fire the handler, the continuation never resumes.
- **Fix:** Set `terminationHandler` before `process.run()`, or check `process.isRunning` after setting the handler (with a guard against double-resume).

### C6. stdin write can deadlock for large transcripts
- **File:** `app/MeetingTranscriber/Sources/ProtocolGenerator.swift`, lines 136-137
- **Problem:** `stdinPipe.fileHandleForWriting.write(promptData)` is synchronous. If the pipe buffer fills (64KB on macOS) and the process isn't reading, this deadlocks — stdout isn't being drained yet.
- **Fix:** Move stdin write into a detached Task, or start reading stdout concurrently with writing stdin.

### C7. AudioBufferList allocation too small for multi-stream devices
- **File:** `app/MeetingTranscriber/Sources/MicRecorder.swift`, lines 124-130
- **Problem:** `UnsafeMutablePointer<AudioBufferList>.allocate(capacity: 1)` allocates space for one `AudioBuffer` inline. Multi-stream devices write past the allocated memory → heap buffer overflow.
- **Fix:** Use `UnsafeMutableRawPointer.allocate(byteCount: Int(bufListSize), alignment:)` and iterate `mNumberBuffers` to sum all channels.

### C8. Data race on `lastState` in MuteDetector
- **File:** `app/MeetingTranscriber/Sources/MuteDetector.swift`, lines 45-54
- **Problem:** `lastState` is read in a detached Task (arbitrary thread) and written inside `MainActor.run`. `@Observable` does not provide thread safety.
- **Fix:** Make `MuteDetector` `@MainActor` and use `Task { }` instead of `Task.detached`, or move all reads into the `MainActor.run` block.

### C9. README.md — Wrong GitHub repository URLs
- **File:** `README.md`, lines 3, 48
- **Problem:** CI badge and clone URL reference `meanstone/Transcriber` but actual remote is `pasrom/meeting-transcriber`.
- **Fix:** Change to `pasrom/meeting-transcriber`.

### C10. Homebrew Cask — Wrong repo URL → release downloads 404
- **File:** `Casks/meeting-transcriber.rb`, lines 5, 8
- **Problem:** Uses `pasrom/Transcriber` (capital T, old name) instead of `pasrom/meeting-transcriber`.
- **Fix:** Update URL to match actual repo.

### C11. ~~APP_PASSWORD leaked via process arguments~~
- **Status:** Won't fix — `@env:` syntax is undocumented and broken. `--password "$APP_PASSWORD"` is the standard approach. For local use, consider `--keychain-profile` instead.

---

## Priority 2: Important (Code Quality, Edge Cases)

### I1. `readStreamJSON` blocks cooperative thread pool
- **File:** `app/MeetingTranscriber/Sources/ProtocolGenerator.swift`, line 182
- **Problem:** `handle.availableData` is blocking synchronous. Inside an `async` function, this blocks a thread from Swift's cooperative pool. For 10-minute timeout, this holds a thread long.
- **Fix:** Wrap in `Task.detached` or use `FileHandle.bytes.lines` (async sequence).

### I2. `onStateChange` closure → retain cycle
- **File:** `app/MeetingTranscriber/Sources/MeetingTranscriberApp.swift`, lines 178-194
- **Problem:** `onStateChange` closure captures `loop` strongly. `WatchLoop` owns `onStateChange` → retain cycle prevents deallocation.
- **Fix:** Use `[weak loop]` in the capture list.

### I3. Duplicated audio processing logic
- **File:** `app/MeetingTranscriber/Sources/DualSourceRecorder.swift`, lines 266-297
- **Problem:** `stop()` manually performs mute masking, echo suppression, and delay alignment — same logic already in `AudioMixer.mix()`. If either copy is updated independently, they drift.
- **Fix:** Call `AudioMixer.mix()` instead of duplicating.

### I4. Linear interpolation resampling → aliasing
- **File:** `app/MeetingTranscriber/Sources/AudioMixer.swift`, lines 207-223
- **Problem:** Downsampling 48kHz→16kHz without anti-aliasing filter. Frequencies above 8kHz alias into output, potentially degrading WhisperKit transcription.
- **Fix:** Use `AVAudioConverter` or apply low-pass filter with `vDSP` before decimation.

### I5. App audio accumulated in RAM without bound
- **File:** `app/MeetingTranscriber/Sources/DualSourceRecorder.swift`, lines 28, 129
- **Problem:** All app audio in `appAudioFrames` array. 2h meeting at 48kHz stereo float32 = ~2.6 GB. Concatenation temporarily doubles memory.
- **Fix:** Write app audio to temp file incrementally.

### I6. `MicRecorder.sampleRate` parameter ignored
- **File:** `app/MeetingTranscriber/Sources/MicRecorder.swift`, lines 55-60
- **Problem:** Tap format uses `hwFormat.sampleRate` (hardware rate), not the requested `sampleRate` parameter. Output WAV may be 44100 Hz despite requesting 48000 Hz.
- **Fix:** Install tap at requested rate (AVAudioEngine can convert) or use `AVAudioConverter`.

### I7. `CancellationError` treated as recording error
- **File:** `app/MeetingTranscriber/Sources/WatchLoop.swift`, line 101
- **Problem:** When `handleMeeting` throws `CancellationError`, it's logged as "Recording error" and sleeps 10s. Should break loop immediately.
- **Fix:** Check `if error is CancellationError { return }` at top of catch block.

### I8. `FluidDiarizer.manager` force-unwrap after failed `prepareModels()`
- **File:** `app/MeetingTranscriber/Sources/FluidDiarizer.swift`, lines 27, 33
- **Problem:** If `prepareModels()` throws, `manager` is set but unprepared. Subsequent call skips re-init (because `manager != nil`) and uses unprepared manager.
- **Fix:** Set `manager` only after `prepareModels()` succeeds.

### I9. WhisperKit model error state hidden
- **File:** `app/MeetingTranscriber/Sources/SettingsView.swift`, lines 130-131
- **Problem:** `default: EmptyView()` hides error state. If model loading fails, user sees nothing — no error, no retry button.
- **Fix:** Add explicit `.error` case with error message and retry button.

### I10. Heavy I/O on main thread in speaker audio playback
- **File:** `app/MeetingTranscriber/Sources/SpeakerNamingView.swift`, lines 225-271
- **Problem:** `AudioMixer.loadWAVAsFloat32`, `AVAudioFile`, `saveWAV`, `AVAudioPlayer` — all synchronous file I/O on UI thread.
- **Fix:** Wrap in `Task.detached`, switch to `@MainActor` only for `player?.play()`.

### I11. Non-atomic write in ParticipantReader
- **File:** `app/MeetingTranscriber/Sources/ParticipantReader.swift`, lines 106-114
- **Problem:** `removeItem` + `moveItem` is not atomic. Between the two, a reader could see no file.
- **Fix:** Use `Data.write(to:options:.atomic)` directly (handles temp file internally).

### I12. Silent regex compilation failures in MeetingDetector
- **File:** `app/MeetingTranscriber/Sources/MeetingDetector.swift`, line 54
- **Problem:** `compactMap { try? NSRegularExpression(pattern: $0) }` silently drops invalid patterns. A typo would silently break detection with no log.
- **Fix:** Use `try!` for compile-time constants, or `assertionFailure` + log.

### I13. Hardcoded frame heights in SettingsView
- **File:** `app/MeetingTranscriber/Sources/SettingsView.swift`, line 195
- **Problem:** `.frame(height: settings.diarize ? 610 : (settings.noMic ? 490 : 590))` — breaks with Dynamic Type, doesn't account for combined states.
- **Fix:** Remove fixed height, use `.frame(width: 420)` and let Form size naturally.

### I14. CI workflows: no timeout, no SPM cache
- **Files:** `.github/workflows/ci.yml`, `.github/workflows/release.yml`
- **Problem:** No `timeout-minutes` on macOS runners ($0.08/min). No SPM dependency caching — WhisperKit + FluidAudio re-downloaded every run.
- **Fix:** Add `timeout-minutes: 30`, add `actions/cache@v4` for `.build/`.

### I15. `GITHUB_TOKEN` cannot push cross-repo → Homebrew tap update broken
- **File:** `.github/workflows/release.yml`, lines 111-132
- **Problem:** `GITHUB_TOKEN` is scoped to current repo. Pushing to `pasrom/homebrew-meeting-transcriber` will 403.
- **Fix:** Use a PAT stored as `secrets.TAP_REPO_TOKEN` with `contents: write` on tap repo.

---

## Priority 3: Cleanup (Dead Code, Stale Docs)

### D1. CLAUDE.md — Missing files in project structure
- **File:** `CLAUDE.md`
- **Problem:** Missing: `tools/whisperkit-cli/`, `scripts/build_whisperkit.sh`, `scripts/notarize_status.sh`, `VERSION`. Stale KeychainHelper description.
- **Fix:** Add missing entries, update descriptions.

### D2. swift-architecture.md — Stale `pyproject.toml` reference
- **File:** `docs/plans/swift-architecture.md`, line 377
- **Problem:** Says `findProjectRoot()` looks for `pyproject.toml`, but actual code uses `VERSION`.
- **Fix:** Update to `VERSION`.

### D3. swift-architecture.md — Stale test count
- **File:** `docs/plans/swift-architecture.md`, line 565
- **Problem:** Says 328 tests, actual is 341.
- **Fix:** Update to 341.

### D4. Completed plan documents with stale Python references
- **Files:** `docs/plans/2026-03-05-whisperkit-integration.md`, `2026-03-07-review-fixes.md`, `swift-migration.md`, `2026-03-10-dual-track-diarization.md`
- **Problem:** All completed. Contain extensive stale Python references that confuse AI agents.
- **Fix:** Archive or delete.

### D5. KeychainHelper.swift — Dead code
- **File:** `app/MeetingTranscriber/Sources/KeychainHelper.swift`
- **Problem:** No production code references it. Only tests use it. HF tokens no longer needed.
- **Fix:** Remove or document as test-only utility.

### D6. .gitignore — Missing entries
- **File:** `.gitignore`
- **Problem:** Missing `__pycache__/`, `.coverage`, `*.pyc`.
- **Fix:** Add entries.

### D7. `chunkSize` computed but unused
- **File:** `app/MeetingTranscriber/Sources/DualSourceRecorder.swift`, line 122
- **Fix:** Remove dead code.

### D8. `import Accelerate` unused
- **File:** `app/MeetingTranscriber/Sources/AudioMixer.swift`, line 1
- **Fix:** Remove (add back when vDSP is actually used).

### D9. audiotap listener block not correctly removed
- **File:** `tools/audiotap/Sources/main.swift`, lines 243-249, 518-525
- **Problem:** `AudioObjectRemovePropertyListenerBlock` requires the same block that was registered. Passing a new closure `{ _, _ in }` never removes the original listener.
- **Fix:** Store the registered block in a property and pass it to the remove call.

---

## Priority 4: Nice-to-have (Optimizations, Future Improvements)

### N1. Scalar loops instead of vDSP in AudioMixer
- **File:** `app/MeetingTranscriber/Sources/AudioMixer.swift`, lines 80-92
- **Fix:** Use `vDSP_vadd`/`vDSP_vsdiv` for better performance on large buffers.

### N2. Hallucination filter only catches consecutive identical segments
- **File:** `app/MeetingTranscriber/Sources/WhisperKitEngine.swift`, lines 133-134
- **Fix:** Add known-hallucination blocklist and sliding-window dedup.

### N3. DateFormatter created per call in ProtocolGenerator
- **File:** `app/MeetingTranscriber/Sources/ProtocolGenerator.swift`, lines 284-286
- **Fix:** Use `static let` cached formatter.

### N4. SPM dependencies use `from:` for pre-1.0 packages
- **File:** `app/MeetingTranscriber/Package.swift`, lines 9-11
- **Fix:** Use `.upToNextMinor(from:)` for 0.x packages.

### N5. Mute detection only supports EN/DE Teams labels
- **File:** `app/MeetingTranscriber/Sources/MuteDetector.swift`, lines 82-84
- **Fix:** Add more locale prefixes or match by AX identifier.

### N6. Non-injectable `UserDefaults.standard` in AppSettings
- **File:** `app/MeetingTranscriber/Sources/AppSettings.swift`, line 3
- **Fix:** Accept `UserDefaults` as init parameter for testability.

### N7. MeetingDetector not `@MainActor` annotated
- **File:** `app/MeetingTranscriber/Sources/MeetingDetector.swift`, line 31
- **Fix:** Add `@MainActor` since it's only used from MainActor context.

---

## Implementation Recommendation

**Phase 1 — Critical concurrency/crash fixes (C1-C8):**
Focus on the speaker naming hang (C1+C3), ProtocolGenerator deadlocks (C5+C6), WhisperKit race (C4), and MuteDetector race (C8). These are real bugs that can crash or hang the app.

**Phase 2 — URLs and security (C9-C11):**
Quick fixes: correct README/Cask URLs, use `@env:` for notarization password.

**Phase 3 — Important improvements (I1-I15):**
Batch by domain: audio pipeline (I3-I6), UI (I9-I10, I13), build/CI (I14-I15).

**Phase 4 — Cleanup (D1-D9):**
Documentation updates, dead code removal, .gitignore fixes.
