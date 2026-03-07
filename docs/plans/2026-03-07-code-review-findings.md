# Code Review Findings — 2026-03-07

Review of Swift macOS app and Python diarization code used by the Swift app.

---

## Critical Issues (Must Fix)

### C1. Pipe Deadlock in DiarizationProcess.swift

**File:** `app/MeetingTranscriber/Sources/DiarizationProcess.swift:130-138`

`process.waitUntilExit()` is called BEFORE `readDataToEndOfFile()` on stdout/stderr. If the Python diarization script writes more than 64KB to stdout (the macOS pipe buffer size), the Python process blocks on write while the Swift process blocks on `waitUntilExit()` — classic pipe deadlock. Diarization JSON with speaker embeddings (512-dimensional float vectors) can easily exceed 64KB.

**Fix:** Read stdout/stderr asynchronously before calling `waitUntilExit()`, or use `terminationHandler` with a continuation:

```swift
try await withCheckedThrowingContinuation { continuation in
    process.terminationHandler = { _ in continuation.resume() }
    try process.run()
}
let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
```

### C2. Blocking Cooperative Thread Pool

**Files:** `DiarizationProcess.swift:130`, `ProtocolGenerator.swift:141`

Both `process.waitUntilExit()` calls are synchronous blocking calls inside `async` functions. They block one of Swift's cooperative thread pool threads (limited to CPU core count). Diarization and protocol generation can each take minutes — blocking two threads can starve the cooperative pool and freeze the app.

**Fix:** Use `Process.terminationHandler` with `withCheckedThrowingContinuation` (see C1). For `ProtocolGenerator`, also move the `handle.availableData` loop (line 171-174) to async I/O via `FileHandle.readabilityHandler` or `AsyncBytes`.

### C3. Data Race on IPCPoller.seenFiles

**File:** `app/MeetingTranscriber/Sources/IPCPoller.swift:30-35, 46-66`

`seenFiles` is a `Set<String>` accessed from a background `Task` (in `poll()`) and mutated from the main thread (in `start()`, `reset()`). No synchronization exists. Concurrent mutation can cause crashes or silent corruption.

**Fix:** Mark `IPCPoller` as `@MainActor`, or protect `seenFiles` with a lock/actor. Since polling is lightweight (1s interval), `@MainActor` is simplest.

### C4. recordingStart Captured at Wrong Time

**File:** `app/MeetingTranscriber/Sources/DualSourceRecorder.swift:150`

```swift
let recordingStart = ProcessInfo.processInfo.systemUptime  // in stop()!
```

This captures system uptime when `stop()` is called, not when recording started. The value is used for mute mask correlation — muted sections will be applied at wrong audio positions.

**Fix:** Capture `ProcessInfo.processInfo.systemUptime` in `start()`, store as instance variable, use in `stop()`.

---

## Important Issues (Should Fix)

### I1. WatchLoop @Observable Mutated from Background

**File:** `app/MeetingTranscriber/Sources/WatchLoop.swift`

`WatchLoop` is `@Observable` with properties read by SwiftUI on the main thread, but mutated from a background `Task` in `watchLoop()` and `handleMeeting()`. This is a data race.

**Fix:** Mark `WatchLoop` as `@MainActor`, or wrap all state mutations in `await MainActor.run { }`.

### I2. Duplicate mix_16k.wav Resampling

**File:** `app/MeetingTranscriber/Sources/WatchLoop.swift:200-203, 229-234`

When `diarizeEnabled` is true, the mix audio is resampled to `mix_16k.wav` twice — once for transcription and again for diarization. Wasted work on potentially large audio files, and the second write overwrites the first.

**Fix:** Resample once, store the URL, reuse.

### I3. WhisperKitEngine Double Loading

**File:** `app/MeetingTranscriber/Sources/WhisperKitEngine.swift:42-71`

`loadModel()` can be called concurrently from app init (line 47-50 in MeetingTranscriberApp.swift) and from `ensureModel()` during transcription. Two models could load simultaneously, wasting memory.

**Fix:** Add an `isLoading` guard or deduplicate with a stored `Task` reference.

### I4. SettingsView Has Separate WhisperKitEngine

**File:** `app/MeetingTranscriber/Sources/SettingsView.swift:35`

```swift
@State private var whisperKitEngine = WhisperKitEngine()
```

This is a separate instance from the one in `MeetingTranscriberApp`. Loading a model in Settings doesn't load it for the pipeline. Model status shown in Settings is disconnected from reality.

**Fix:** Pass the app's `WhisperKitEngine` instance into `SettingsView`.

### I5. Speaker Count IPC Never Called in Standalone Script

**File:** `tools/diarize/diarize.py:282-309`

`write_speaker_count_request()` and `poll_speaker_count_response()` exist but are never called in `run_full_pipeline()`. The Swift UI for speaker count is fully wired (`SpeakerCountView`, `IPCPoller`, `IPCManager`), but the Python script never asks for it.

**Fix:** Call speaker count IPC in `run_full_pipeline()` when `--ipc-dir` is provided and `--speakers` is not set.

### I6. No Timeout for Diarization Subprocess

**File:** `app/MeetingTranscriber/Sources/DiarizationProcess.swift`

`process.waitUntilExit()` blocks indefinitely with no timeout. If Python hangs (model download stalls, GPU issue), the app stays in `diarizing` state forever. Compare with `ProtocolGenerator` which has `TIMEOUT_SECONDS = 600`.

**Fix:** Add a timeout mechanism — e.g., cancel the process after N seconds.

### I7. MeetingDetector Over-Counts in Single Poll

**File:** `app/MeetingTranscriber/Sources/MeetingDetector.swift:64`

If multiple windows match the same pattern (e.g., Teams has multiple meeting-titled windows), the consecutive hit counter increments multiple times per poll. `confirmationCount: 2` could be satisfied in a single poll, defeating the purpose of requiring persistence across multiple cycles.

**Fix:** Use a Set to track which patterns matched per round, increment by 1 per pattern per round.

### I8. AppSettings() Created Separately in init()

**File:** `app/MeetingTranscriber/Sources/MeetingTranscriberApp.swift:48`

```swift
engine.modelVariant = AppSettings().whisperKitModel  // new instance!
```

Creates a separate `AppSettings` instance instead of using `self.settings`. While `UserDefaults` backing means the value is likely the same, it breaks the single-source-of-truth contract.

**Fix:** Move to `.task` modifier that can access `settings`.

---

## Python-Specific Issues

### P1. SpeakerRequest Missing expected_names Field

**Files:** `tools/diarize/diarize.py:256`, `app/MeetingTranscriber/Sources/SpeakerRequest.swift`

Python writes `expected_names` in `speaker_request.json`, but Swift's `SpeakerRequest` struct doesn't declare the field. It's silently ignored by `Codable`. The `SpeakerNamingView` can't use expected names as suggestions.

**Fix:** Add `let expectedNames: [String]?` with `CodingKey "expected_names"` to `SpeakerRequest`.

### P2. dotenv Import Without Guard

**File:** `src/meeting_transcriber/diarize.py:503-505`

```python
from dotenv import load_dotenv  # hard import, no try/except
```

If `python-dotenv` is not installed, this raises `ImportError`. The standalone script (`tools/diarize/diarize.py`) correctly wraps this in try/except.

**Fix:** Add try/except around the import.

### P3. Speaker Embedding Index Ordering Assumption

**Files:** `tools/diarize/diarize.py:409`, `src/meeting_transcriber/diarize.py:692`

Embeddings are mapped to speaker labels by array index:
```python
for i, label in enumerate(speaker_labels):
    if i < len(raw_embeddings):
        embeddings[label] = np.array(raw_embeddings[i])
```

This assumes pyannote returns embeddings in the same order as alphabetically sorted labels. If the order differs, embeddings are assigned to wrong speakers, causing incorrect voice matching against `speakers.json`.

**Fix:** Verify pyannote's ordering guarantee, or use a more robust mapping (e.g., by speaker label key).

### P4. poll_speaker_response Returns None on Parse Error

**Files:** `tools/diarize/diarize.py:276-278`, `src/meeting_transcriber/diarize.py:401-403`

If `json.JSONDecodeError` occurs during response polling, the entire speaker naming round is lost without retry. While atomic writes make this unlikely, a single retry would be more robust.

### P5. save_speaker_db Truncates Before Locking

**File:** `tools/diarize/diarize.py`

`open(path, "w")` truncates the file before `fcntl.flock()` acquires the lock. If two processes write simultaneously, one could truncate while the other reads. Unlikely in practice (single-instance), but the safer pattern is write-to-temp + `os.replace()`.

---

## Summary

| Severity | Count | Most Impactful |
|----------|-------|----------------|
| Critical | 4 | C1 Pipe deadlock, C2 Thread pool blocking |
| Important | 8 | I1 WatchLoop data race, I5 Speaker count IPC gap |
| Python | 5 | P1 Missing expected_names, P3 Embedding ordering |

**Priority order for fixes:**
1. C1 + C2: Pipe deadlock and thread blocking (app hangs)
2. C3: IPCPoller data race (potential crash)
3. C4: recordingStart timing (incorrect mute masking)
4. I1: WatchLoop thread safety
5. I5: Speaker count IPC activation
6. I4: WhisperKitEngine instance sharing
