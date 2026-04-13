# Re-openable Speaker Naming Dialog — Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Allow users to re-open the speaker naming dialog at any time after it was dismissed or timed out, so speaker assignments are never lost — especially important for back-to-back meetings. Include late re-diarization with different speaker counts.

**Architecture:** Replace the single-use `CheckedContinuation` with a queue of pending `SpeakerNamingData` items persisted to disk. The pipeline awaits naming via the existing continuation pattern but with a timeout that only unblocks the pipeline — it does NOT discard the naming data. All data needed for re-diarization and re-naming (16kHz audio, transcript segments, diarization data) is persisted to `recordings/` as JSON sidecar files. Disk is the source of truth — RAM is a cache loaded on startup. Auto-cleanup after 24h prevents unbounded disk growth.

**Tech Stack:** Swift, SwiftUI, `Codable`, `@Observable`

**Addresses:** [GitHub Issue #106](https://github.com/pasrom/meeting-transcriber/issues/106)

---

## Overview

The current flow uses `CheckedContinuation` (single-use) with a 120s timeout. After timeout or dismissal, `pendingSpeakerNaming` is set to `nil` and the pipeline moves on with auto-names. There is no way to go back.

The new flow:
1. **No timeout on data** — dialog stays available until explicitly confirmed, skipped, or auto-cleaned after 24h
2. **Pending queue** — multiple naming requests can queue up (back-to-back meetings), no hard limit
3. **Disk-persisted** — all naming data (audio, segments, embeddings, mapping) saved as JSON sidecar files in `recordings/` — survives app crashes and restarts
4. **Menu bar always shows** "Name Speakers..." when pending items exist
5. **Late re-diarization** — user can re-run diarization with different speaker count even after pipeline completed
6. **Late re-apply** — confirming names re-generates the transcript with proper speaker labels and re-runs protocol generation
7. **Auto-cleanup** — pending items older than 24h are automatically resolved with auto-names and cleaned up

### Key Design Decisions

- **Disk is source of truth**: `SpeakerNamingData` serialized as `{slug}_naming.json` in `recordings/`. RAM dictionary is a cache, rebuilt from disk on `loadSnapshot()`.
- **Pipeline timeout unblocks only**: After `speakerNamingTimeout` (120s), the pipeline resumes with auto-names but the naming data stays on disk. The job transitions to `.speakerNamingPending` after pipeline completes.
- **Late re-diarization is possible**: Original audio files (`_mix.wav`, `_app.wav`, `_mic.wav`) are already saved to `recordings/`. The 16kHz resampled versions (`_16k.wav`) are additionally preserved. `diarizationFactory()` can create a fresh provider at any time.
- **Transcript segments persisted**: `cachedSegments` saved as `{slug}_segments.json` — needed for `assignSpeakers`/`assignSpeakersDualTrack` during late re-naming.
- **No hard limit on pending items**: Each naming sidecar is ~10-50KB. Audio files are the bulk but are already saved. 24h auto-cleanup prevents unbounded growth.

### Data Persistence Layout

```
protocols/recordings/
  20260413_140000_mix.wav        # already saved (copyAudioToOutput)
  20260413_140000_app.wav        # already saved (dual-track)
  20260413_140000_mic.wav        # already saved (dual-track)
  20260413_140000_16k.wav        # NEW: 16kHz mix for playback
  20260413_140000_app_16k.wav    # NEW: 16kHz app track for re-diarization (dual-track only)
  20260413_140000_mic_16k.wav    # NEW: 16kHz mic track for re-diarization (dual-track only)
  20260413_140000_naming.json    # NEW: SpeakerNamingData (mapping, embeddings, speakingTimes, segments, participants)
  20260413_140000_segments.json  # NEW: cached TimestampedSegments for re-assignment
```

---

## Task 1: Add `speakerNamingPending` state to `JobState`

Track that a job is done but has unconfirmed speaker names.

**Files:**
- Modify: `app/MeetingTranscriber/Sources/PipelineJob.swift:3-23`

**Step 1: Write the failing test**

In `app/MeetingTranscriber/Tests/PipelineQueueTests.swift`, add:

```swift
func testJobStateSpeakerNamingPendingLabel() {
    XCTAssertEqual(JobState.speakerNamingPending.label, "Name Speakers...")
}

func testJobStateSpeakerNamingPendingIsCodable() throws {
    let state = JobState.speakerNamingPending
    let data = try JSONEncoder().encode(state)
    let decoded = try JSONDecoder().decode(JobState.self, from: data)
    XCTAssertEqual(decoded, state)
}
```

**Step 2: Run test to verify it fails**

Run: `cd app/MeetingTranscriber && swift test --filter testJobStateSpeakerNamingPendingLabel`
Expected: Compilation error — `speakerNamingPending` doesn't exist

**Step 3: Add the new case to `JobState`**

In `PipelineJob.swift`, add the new case after `generatingProtocol`:

```swift
enum JobState: String, Codable {
    case waiting
    case transcribing
    case diarizing
    // swiftlint:disable:next raw_value_for_camel_cased_codable_enum
    case generatingProtocol
    // swiftlint:disable:next raw_value_for_camel_cased_codable_enum
    case speakerNamingPending
    case done
    case error

    var label: String {
        switch self {
        case .waiting: "Waiting..."
        case .transcribing: "Transcribing..."
        case .diarizing: "Diarizing..."
        case .generatingProtocol: "Generating Protocol..."
        case .speakerNamingPending: "Name Speakers..."
        case .done: "Done"
        case .error: "Error"
        }
    }
}
```

**Step 4: Fix all `switch` exhaustiveness errors**

Add `.speakerNamingPending` handling in:
- `MenuBarView.swift:jobColor` — return `.purple`
- `MenuBarView.swift:jobRow` — show "Name Speakers" button alongside Dismiss
- `PipelineQueue.swift:cancelJob` — treat like `.done` (no cancel)
- `PipelineQueue.swift:loadSnapshot` — keep as-is (don't reset to `.waiting`)
- `PipelineQueue.swift:updateJobState` — don't auto-remove or markProcessed

**Step 5: Run tests to verify they pass**

Run: `cd app/MeetingTranscriber && swift test`
Expected: All tests pass

**Step 6: Commit**

```bash
git add app/MeetingTranscriber/Sources/PipelineJob.swift app/MeetingTranscriber/Sources/MenuBarView.swift app/MeetingTranscriber/Sources/PipelineQueue.swift app/MeetingTranscriber/Tests/PipelineQueueTests.swift
git commit -m "feat(app): add speakerNamingPending job state for re-openable dialog"
```

---

## Task 2: Make `SpeakerNamingData` Codable and persist to disk

All naming data must survive app crashes. Disk is the source of truth.

**Files:**
- Modify: `app/MeetingTranscriber/Sources/PipelineQueue.swift:40-76`

**Step 1: Write the failing test**

In `PipelineQueueTests.swift`:

```swift
func testSpeakerNamingDataRoundTripsThroughJSON() throws {
    let data = PipelineQueue.SpeakerNamingData(
        jobID: UUID(),
        meetingTitle: "Test Meeting",
        mapping: ["SPEAKER_0": "Alice", "SPEAKER_1": "Bob"],
        speakingTimes: ["SPEAKER_0": 120.5, "SPEAKER_1": 85.3],
        embeddings: ["SPEAKER_0": [0.1, 0.2], "SPEAKER_1": [0.3, 0.4]],
        audioPath: URL(fileURLWithPath: "/tmp/test_16k.wav"),
        segments: [
            .init(start: 0.0, end: 5.0, speaker: "SPEAKER_0"),
            .init(start: 5.0, end: 10.0, speaker: "SPEAKER_1"),
        ],
        participants: ["Alice", "Bob", "Charlie"],
        isDualSource: false,
    )

    let encoded = try JSONEncoder().encode(data)
    let decoded = try JSONDecoder().decode(PipelineQueue.SpeakerNamingData.self, from: encoded)

    XCTAssertEqual(decoded.jobID, data.jobID)
    XCTAssertEqual(decoded.meetingTitle, data.meetingTitle)
    XCTAssertEqual(decoded.mapping, data.mapping)
    XCTAssertEqual(decoded.participants, data.participants)
    XCTAssertEqual(decoded.isDualSource, false)
}
```

**Step 2: Run test to verify it fails**

Expected: Compilation error — `SpeakerNamingData` does not conform to `Codable`

**Step 3: Make `SpeakerNamingData` Codable**

```swift
struct SpeakerNamingData: Codable {
    let jobID: UUID
    let meetingTitle: String
    let mapping: [String: String]
    let speakingTimes: [String: TimeInterval]
    let embeddings: [String: [Float]]
    let audioPath: URL?
    let segments: [Segment]
    let participants: [String]
    let isDualSource: Bool

    struct Segment: Codable {
        let start: TimeInterval
        let end: TimeInterval
        let speaker: String
    }
}
```

Note: `SpeakerNamingData.Segment` is a new Codable struct. The existing `DiarizationResult.Segment` is not Codable — we convert at the boundary.

**Step 4: Add save/load helpers**

```swift
/// Save naming data as a JSON sidecar file alongside the recording.
func saveNamingData(_ data: SpeakerNamingData, slug: String) {
    guard let outputDir else { return }
    let recordingsDir = outputDir.appendingPathComponent("recordings")
    let path = recordingsDir.appendingPathComponent("\(slug)_naming.json")
    do {
        let json = try JSONEncoder().encode(data)
        try json.write(to: path, options: .atomic)
    } catch {
        logger.error("Failed to save naming data: \(error)")
    }
}

/// Load naming data from a JSON sidecar file.
func loadNamingData(slug: String) -> SpeakerNamingData? {
    guard let outputDir else { return nil }
    let path = outputDir.appendingPathComponent("recordings/\(slug)_naming.json")
    guard let json = try? Data(contentsOf: path) else { return nil }
    return try? JSONDecoder().decode(SpeakerNamingData.self, from: json)
}

/// Delete naming data sidecar file.
func deleteNamingData(slug: String) {
    guard let outputDir else { return }
    let path = outputDir.appendingPathComponent("recordings/\(slug)_naming.json")
    try? FileManager.default.removeItem(at: path)
}
```

**Step 5: Add `namingSlug` to `PipelineJob`**

In `PipelineJob.swift`, add a computed property to derive the slug from `transcriptPath` or `meetingTitle`:

```swift
struct PipelineJob: Identifiable, Codable {
    // ... existing properties ...
    /// Slug used for naming sidecar files (derived from transcript filename).
    var namingSlug: String?
}
```

Set this in `processNext()` when the transcript is saved (same slug used by `ProtocolGenerator.filename`).

**Step 6: Store naming data per job in RAM cache**

```swift
/// RAM cache of naming data, rebuilt from disk on loadSnapshot().
/// Keyed by job ID. Disk (_naming.json) is the source of truth.
private(set) var speakerNamingDataByJob: [UUID: SpeakerNamingData] = [:]

/// The currently displayed naming data (first pending item).
var pendingSpeakerNaming: SpeakerNamingData? {
    guard let firstPendingJob = pendingSpeakerNamingJobs.first else { return nil }
    return speakerNamingDataByJob[firstPendingJob.id]
}

/// Jobs that have unconfirmed speaker naming data.
var pendingSpeakerNamingJobs: [PipelineJob] {
    jobs.filter { $0.state == .speakerNamingPending }
}
```

**Step 7: Run tests**

Run: `cd app/MeetingTranscriber && swift test`
Expected: All pass

**Step 8: Commit**

```bash
git add app/MeetingTranscriber/Sources/PipelineQueue.swift app/MeetingTranscriber/Sources/PipelineJob.swift app/MeetingTranscriber/Tests/PipelineQueueTests.swift
git commit -m "feat(app): make SpeakerNamingData Codable and persist to disk as sidecar JSON"
```

---

## Task 3: Persist 16kHz audio and transcript segments for re-diarization

Save 16kHz audio files and cached transcript segments to `recordings/` so late re-diarization and re-assignment are possible even after app restart.

**Files:**
- Modify: `app/MeetingTranscriber/Sources/PipelineQueue.swift` (processNext)

**Step 1: Write the failing test**

```swift
func testPersistedFilesExistAfterPipeline() async throws {
    let pQueue = try makePipelineQueue(diarizeEnabled: true)
    pQueue.speakerNamingHandler = { _ in .skipped }

    let audioPath = try createTestAudioFile(in: tmpDir)
    let job = PipelineJob(
        meetingTitle: "Persist Test",
        appName: "TestApp",
        mixPath: audioPath,
        appPath: nil,
        micPath: nil,
        micDelay: 0,
    )
    pQueue.enqueue(job)
    try await Task.sleep(for: .seconds(5))

    // Check that sidecar files exist
    let outputDir = pQueue.outputDir!
    let recordingsDir = outputDir.appendingPathComponent("recordings")
    let slug = pQueue.jobs.first!.namingSlug!

    // 16kHz mix for playback
    let mix16k = recordingsDir.appendingPathComponent("\(slug)_16k.wav")
    XCTAssertTrue(FileManager.default.fileExists(atPath: mix16k.path))

    // Naming data JSON
    let namingJSON = recordingsDir.appendingPathComponent("\(slug)_naming.json")
    XCTAssertTrue(FileManager.default.fileExists(atPath: namingJSON.path))

    // Transcript segments JSON
    let segmentsJSON = recordingsDir.appendingPathComponent("\(slug)_segments.json")
    XCTAssertTrue(FileManager.default.fileExists(atPath: segmentsJSON.path))
}
```

**Step 2: Persist 16kHz audio files**

In `processNext()`, after resampling but before the `defer { removeItem(workDir) }` cleanup, copy 16kHz files to `recordings/`:

```swift
// After transcript is saved and slug is known:

let recordingsDir = outputDir.appendingPathComponent("recordings")

// Copy 16kHz mix
let mix16kSrc = workDir.appendingPathComponent("mix_16k.wav")
if FileManager.default.fileExists(atPath: mix16kSrc.path) {
    let dst = recordingsDir.appendingPathComponent("\(slug)_16k.wav")
    try? FileManager.default.copyItem(at: mix16kSrc, to: dst)
}

// Dual-track: also copy app and mic 16kHz
if isDualSource {
    let app16kSrc = workDir.appendingPathComponent("app_16k.wav")
    let mic16kSrc = workDir.appendingPathComponent("mic_16k.wav")
    if FileManager.default.fileExists(atPath: app16kSrc.path) {
        let dst = recordingsDir.appendingPathComponent("\(slug)_app_16k.wav")
        try? FileManager.default.copyItem(at: app16kSrc, to: dst)
    }
    if FileManager.default.fileExists(atPath: mic16kSrc.path) {
        let dst = recordingsDir.appendingPathComponent("\(slug)_mic_16k.wav")
        try? FileManager.default.copyItem(at: mic16kSrc, to: dst)
    }
}
```

**Step 3: Persist transcript segments**

Make `TimestampedSegment` conform to `Codable` (if not already), then save:

```swift
// Save cached segments for late re-assignment
if let cachedSegments {
    let segPath = recordingsDir.appendingPathComponent("\(slug)_segments.json")
    if let data = try? JSONEncoder().encode(cachedSegments) {
        try? data.write(to: segPath, options: .atomic)
    }
}
```

**Step 4: Update naming data audioPath to reference persisted file**

When creating `SpeakerNamingData`, use the persisted path:

```swift
let persistedMix16k = recordingsDir.appendingPathComponent("\(slug)_16k.wav")
let namingData = SpeakerNamingData(
    // ...
    audioPath: persistedMix16k,  // references disk, not temp workDir
    // ...
    isDualSource: isDualSource,
)
```

**Step 5: Run tests**

Run: `cd app/MeetingTranscriber && swift test`
Expected: All pass

**Step 6: Commit**

```bash
git add app/MeetingTranscriber/Sources/PipelineQueue.swift app/MeetingTranscriber/Tests/PipelineQueueTests.swift
git commit -m "feat(app): persist 16kHz audio and transcript segments for late re-diarization"
```

---

## Task 4: Replace timeout with non-blocking pipeline flow

The pipeline should not block indefinitely on speaker naming. After timeout, it moves on with auto-names but keeps naming data on disk for later.

**Files:**
- Modify: `app/MeetingTranscriber/Sources/PipelineQueue.swift:353-453`

**Step 1: Write the failing test**

```swift
func testPipelineCompletesAndKeepsNamingDataAfterTimeout() async throws {
    let pQueue = try makePipelineQueue(diarizeEnabled: true)
    // Don't set speakerNamingHandler — simulate no user response

    let audioPath = try createTestAudioFile(in: tmpDir)
    let job = PipelineJob(
        meetingTitle: "Timeout Test",
        appName: "TestApp",
        mixPath: audioPath,
        appPath: nil,
        micPath: nil,
        micDelay: 0,
    )
    pQueue.enqueue(job)

    // Wait for pipeline to complete (timeout + processing)
    try await Task.sleep(for: .seconds(10))

    // Job should be in speakerNamingPending (not stuck, not lost)
    let finalJob = pQueue.jobs.first
    XCTAssertEqual(finalJob?.state, .speakerNamingPending)

    // Naming data should still be available
    XCTAssertNotNil(pQueue.speakerNamingDataByJob[job.id])
}
```

**Step 2: Refactor the diarization loop**

The key change: timeout resumes the pipeline with `.skipped` but does NOT remove naming data from disk or RAM cache.

```swift
// After diarization + naming data computed and saved to disk:
self.speakerNamingDataByJob[jobID] = namingData
saveNamingData(namingData, slug: slug)
NotificationCenter.default.post(name: .showSpeakerNaming, object: nil)

stopElapsedTimer()
let namingResult: SpeakerNamingResult
if let handler = speakerNamingHandler {
    namingResult = await handler(namingData)
} else {
    namingResult = await withCheckedContinuation { continuation in
        self.speakerNamingContinuation = continuation
        let timeoutTask = Task { [weak self] in
            try await Task.sleep(for: .seconds(Self.speakerNamingTimeout))
            // Resume pipeline but DON'T remove naming data
            guard let cont = self?.speakerNamingContinuation else { return }
            self?.speakerNamingContinuation = nil
            cont.resume(returning: .skipped)
        }
        self.speakerNamingTimeoutTask = timeoutTask
    }
    speakerNamingTimeoutTask?.cancel()
    speakerNamingTimeoutTask = nil
}
```

After pipeline completes, check if naming data still exists:

```swift
// At end of processNext(), replace updateJobState(id: jobID, to: .done):
if speakerNamingDataByJob[jobID] != nil {
    updateJobState(id: jobID, to: .speakerNamingPending)
} else {
    updateJobState(id: jobID, to: .done)
}
```

**Step 3: Add `speakerNamingTimeoutTask` property**

```swift
private var speakerNamingTimeoutTask: Task<Void, Never>?
```

**Step 4: Update `completeSpeakerNaming` to handle in-flight vs. late**

```swift
func completeSpeakerNaming(jobID: UUID, result: SpeakerNamingResult) {
    // If continuation exists → pipeline is still waiting → resume it
    if let continuation = speakerNamingContinuation {
        speakerNamingContinuation = nil
        speakerNamingTimeoutTask?.cancel()
        speakerNamingTimeoutTask = nil
        if case .confirmed = result {
            speakerNamingDataByJob.removeValue(forKey: jobID)
            deleteNamingData(slug: jobs.first { $0.id == jobID }?.namingSlug)
        }
        continuation.resume(returning: result)
        return
    }

    // Late confirmation → pipeline already completed → handled in Task 6
    handleLateNaming(jobID: jobID, result: result)
}

// Backward-compat overload
func completeSpeakerNaming(result: SpeakerNamingResult) {
    guard let jobID = pendingSpeakerNamingJobs.first?.id else { return }
    completeSpeakerNaming(jobID: jobID, result: result)
}
```

**Step 5: Run tests**

Run: `cd app/MeetingTranscriber && swift test`
Expected: All pass

**Step 6: Commit**

```bash
git add app/MeetingTranscriber/Sources/PipelineQueue.swift app/MeetingTranscriber/Tests/PipelineQueueTests.swift
git commit -m "feat(app): pipeline continues after naming timeout, keeps data on disk for later"
```

---

## Task 5: Show "Name Speakers..." button based on pending naming data

Currently the button is gated on `state == .waitingForSpeakerNames` (a `TranscriberState` from WatchLoop). Change it to show whenever pending naming jobs exist.

**Files:**
- Modify: `app/MeetingTranscriber/Sources/MenuBarView.swift:91-98`
- Modify: `app/MeetingTranscriber/Sources/MeetingTranscriberApp.swift:49-51`

**Step 1: Change condition in `MenuBarView`**

Replace the current gating:

```swift
// OLD:
if state == .waitingForSpeakerNames, let onNameSpeakers {

// NEW:
if let onNameSpeakers {
```

The `onNameSpeakers` closure is now conditionally provided:

```swift
// In MeetingTranscriberApp.swift:
onNameSpeakers: appState.pipelineQueue.pendingSpeakerNamingJobs.isEmpty ? nil : {
    bringWindowToFront(id: "speaker-naming")
},
```

**Step 2: Show per-job "Name Speakers" in job row**

In `MenuBarView.jobRow`, for `.speakerNamingPending` jobs:

```swift
if job.state == .speakerNamingPending {
    Button("Name Speakers") { onNameSpeakers?() }
        .font(.caption2)
}
```

**Step 3: Run tests**

Run: `cd app/MeetingTranscriber && swift test`
Expected: All pass

**Step 4: Commit**

```bash
git add app/MeetingTranscriber/Sources/MenuBarView.swift app/MeetingTranscriber/Sources/MeetingTranscriberApp.swift
git commit -m "feat(app): show Name Speakers button whenever pending naming jobs exist"
```

---

## Task 6: Late re-apply speaker names (confirmed)

When the user names speakers after the pipeline completed, re-generate the transcript with correct names and re-run protocol generation.

**Files:**
- Modify: `app/MeetingTranscriber/Sources/PipelineQueue.swift`

**Step 1: Write the failing test**

```swift
func testLateConfirmationRewritesTranscript() async throws {
    let pQueue = try makePipelineQueue(diarizeEnabled: true)
    pQueue.speakerNamingHandler = { _ in .skipped }

    let audioPath = try createTestAudioFile(in: tmpDir)
    let job = PipelineJob(
        meetingTitle: "Late Naming Test",
        appName: "TestApp",
        mixPath: audioPath,
        appPath: nil,
        micPath: nil,
        micDelay: 0,
    )
    pQueue.enqueue(job)
    try await Task.sleep(for: .seconds(5))

    let jobID = job.id
    XCTAssertEqual(pQueue.jobs.first?.state, .speakerNamingPending)

    // Simulate late confirmation
    pQueue.completeSpeakerNaming(jobID: jobID, result: .confirmed(["SPEAKER_0": "Alice"]))
    try await Task.sleep(for: .seconds(3))

    // Job should be .done, naming data cleared
    XCTAssertEqual(pQueue.jobs.first { $0.id == jobID }?.state, .done)
    XCTAssertNil(pQueue.speakerNamingDataByJob[jobID])
}
```

**Step 2: Implement `handleLateNaming` for `.confirmed`**

```swift
private func handleLateNaming(jobID: UUID, result: SpeakerNamingResult) {
    guard let namingData = speakerNamingDataByJob[jobID],
          let jobIndex = jobs.firstIndex(where: { $0.id == jobID }) else { return }
    let slug = jobs[jobIndex].namingSlug

    switch result {
    case let .confirmed(userMapping):
        Task {
            await reapplySpeakerNames(jobID: jobID, mapping: userMapping)
        }

    case let .rerun(count):
        Task {
            await lateDiarization(jobID: jobID, speakerCount: count)
        }

    case .skipped:
        speakerNamingDataByJob.removeValue(forKey: jobID)
        if let slug { deleteNamingData(slug: slug) }
        cleanupSidecarFiles(slug: slug)
        updateJobState(id: jobID, to: .done)
    }
}
```

**Step 3: Implement `reapplySpeakerNames`**

```swift
/// Re-apply speaker names after the pipeline already completed.
/// Loads saved segments from disk, re-runs assignSpeakers with new names,
/// re-writes transcript, and re-generates protocol.
private func reapplySpeakerNames(jobID: UUID, mapping: [String: String]) async {
    guard let namingData = speakerNamingDataByJob[jobID],
          let jobIndex = jobs.firstIndex(where: { $0.id == jobID }),
          let transcriptPath = jobs[jobIndex].transcriptPath else { return }

    // Update speaker matcher DB
    let matcher = speakerMatcherFactory()
    var fullMapping = namingData.mapping
    for (label, name) in mapping where !name.isEmpty {
        fullMapping[label] = name
    }
    matcher.updateDB(mapping: fullMapping, embeddings: namingData.embeddings)

    do {
        // Re-read and re-write transcript with new speaker names
        var transcript = try String(contentsOf: transcriptPath, encoding: .utf8)
        for (label, name) in mapping where !name.isEmpty {
            transcript = transcript.replacingOccurrences(of: "[\(label)]", with: "[\(name)]")
            if let autoName = namingData.mapping[label], autoName != label, autoName != name {
                transcript = transcript.replacingOccurrences(of: "[\(autoName)]", with: "[\(name)]")
            }
        }
        try transcript.write(to: transcriptPath, atomically: true, encoding: .utf8)

        // Re-generate protocol
        if let protocolGeneratorFactory, let generator = protocolGeneratorFactory() {
            updateJobState(id: jobID, to: .generatingProtocol)
            startElapsedTimer()
            let diarized = transcript.range(of: #"\[\w[\w\s]*\]"#, options: .regularExpression) != nil
            let title = jobs[jobIndex].meetingTitle
            let protocolMD = try await generator.generate(
                transcript: transcript, title: title, diarized: diarized,
            )
            let fullMD = protocolMD + "\n\n---\n\n## Full Transcript\n\n" + transcript
            if let outputDir {
                let protocolsDir = outputDir.appendingPathComponent("protocols")
                let mdPath = try ProtocolGenerator.saveProtocol(fullMD, title: title, dir: protocolsDir)
                jobs[jobIndex].protocolPath = mdPath
            }
            stopElapsedTimer()
        }
    } catch {
        logger.error("Failed to re-apply speaker names: \(error)")
    }

    let slug = jobs[jobIndex].namingSlug
    speakerNamingDataByJob.removeValue(forKey: jobID)
    if let slug { deleteNamingData(slug: slug) }
    cleanupSidecarFiles(slug: slug)
    updateJobState(id: jobID, to: .done)
}
```

**Step 4: Run tests**

Run: `cd app/MeetingTranscriber && swift test`
Expected: All pass

**Step 5: Commit**

```bash
git add app/MeetingTranscriber/Sources/PipelineQueue.swift app/MeetingTranscriber/Tests/PipelineQueueTests.swift
git commit -m "feat(app): re-apply speaker names and regenerate protocol on late confirmation"
```

---

## Task 7: Late re-diarization with different speaker count

When the user clicks "Re-run" after the pipeline completed, re-diarize from persisted 16kHz audio.

**Files:**
- Modify: `app/MeetingTranscriber/Sources/PipelineQueue.swift`

**Step 1: Write the failing test**

```swift
func testLateRerunDiarizesFromPersistedAudio() async throws {
    let pQueue = try makePipelineQueue(diarizeEnabled: true)
    pQueue.speakerNamingHandler = { _ in .skipped }

    let audioPath = try createTestAudioFile(in: tmpDir)
    let job = PipelineJob(
        meetingTitle: "Late Rerun Test",
        appName: "TestApp",
        mixPath: audioPath,
        appPath: nil,
        micPath: nil,
        micDelay: 0,
    )
    pQueue.enqueue(job)
    try await Task.sleep(for: .seconds(5))

    XCTAssertEqual(pQueue.jobs.first?.state, .speakerNamingPending)

    // Now re-run with 3 speakers — should re-diarize and show naming dialog again
    var rerunHandlerCalled = false
    pQueue.speakerNamingHandler = { data in
        rerunHandlerCalled = true
        XCTAssertEqual(data.meetingTitle, "Late Rerun Test")
        return .confirmed(["SPEAKER_0": "Alice", "SPEAKER_1": "Bob", "SPEAKER_2": "Charlie"])
    }

    pQueue.completeSpeakerNaming(jobID: job.id, result: .rerun(3))
    try await Task.sleep(for: .seconds(5))

    XCTAssertTrue(rerunHandlerCalled)
    XCTAssertEqual(pQueue.jobs.first?.state, .done)
}
```

**Step 2: Implement `lateDiarization`**

```swift
/// Re-run diarization from persisted 16kHz audio after pipeline completed.
private func lateDiarization(jobID: UUID, speakerCount: Int) async {
    guard let namingData = speakerNamingDataByJob[jobID],
          let jobIndex = jobs.firstIndex(where: { $0.id == jobID }),
          let diarizationFactory,
          let slug = jobs[jobIndex].namingSlug,
          let outputDir else { return }

    let recordingsDir = outputDir.appendingPathComponent("recordings")
    let diarizeProcess = diarizationFactory()
    guard diarizeProcess.isAvailable else {
        logger.warning("Diarization not available for late re-run")
        return
    }

    updateJobState(id: jobID, to: .diarizing)
    startElapsedTimer()

    do {
        let title = jobs[jobIndex].meetingTitle
        let diarization: DiarizationResult

        if namingData.isDualSource {
            // Dual-track: re-diarize both tracks
            let app16k = recordingsDir.appendingPathComponent("\(slug)_app_16k.wav")
            let mic16k = recordingsDir.appendingPathComponent("\(slug)_mic_16k.wav")
            let appDiar = try await diarizeProcess.run(
                audioPath: app16k, numSpeakers: speakerCount, meetingTitle: title,
            )
            let micDiar = try await diarizeProcess.run(
                audioPath: mic16k, numSpeakers: nil, meetingTitle: title,
            )
            diarization = DiarizationProcess.mergeDualTrackDiarization(
                appDiarization: appDiar, micDiarization: micDiar,
            )
        } else {
            let mix16k = recordingsDir.appendingPathComponent("\(slug)_16k.wav")
            diarization = try await diarizeProcess.run(
                audioPath: mix16k, numSpeakers: speakerCount, meetingTitle: title,
            )
        }

        stopElapsedTimer()

        guard let embeddings = diarization.embeddings else { return }
        let matcher = speakerMatcherFactory()
        var autoNames = matcher.match(embeddings: embeddings)

        if !namingData.participants.isEmpty {
            autoNames = SpeakerMatcher.preMatchParticipants(
                mapping: autoNames,
                speakingTimes: diarization.speakingTimes,
                participants: namingData.participants,
            )
        }

        // Build new naming data with fresh diarization results
        let newNamingData = SpeakerNamingData(
            jobID: jobID,
            meetingTitle: title,
            mapping: autoNames,
            speakingTimes: diarization.speakingTimes,
            embeddings: embeddings,
            audioPath: namingData.audioPath, // same persisted 16kHz mix
            segments: diarization.segments.map {
                SpeakerNamingData.Segment(start: $0.start, end: $0.end, speaker: $0.speaker)
            },
            participants: namingData.participants,
            isDualSource: namingData.isDualSource,
        )

        // Update disk + RAM
        speakerNamingDataByJob[jobID] = newNamingData
        saveNamingData(newNamingData, slug: slug)

        // Show naming dialog again
        updateJobState(id: jobID, to: .speakerNamingPending)
        NotificationCenter.default.post(name: .showSpeakerNaming, object: nil)

        // If test handler is set, call it directly
        if let handler = speakerNamingHandler {
            let result = await handler(newNamingData)
            completeSpeakerNaming(jobID: jobID, result: result)
        }
    } catch {
        logger.error("Late re-diarization failed: \(error)")
        stopElapsedTimer()
        updateJobState(id: jobID, to: .speakerNamingPending) // back to pending, user can retry
    }
}
```

**Step 3: Run tests**

Run: `cd app/MeetingTranscriber && swift test`
Expected: All pass

**Step 4: Commit**

```bash
git add app/MeetingTranscriber/Sources/PipelineQueue.swift app/MeetingTranscriber/Tests/PipelineQueueTests.swift
git commit -m "feat(app): support late re-diarization with different speaker count from persisted audio"
```

---

## Task 8: Prevent auto-removal of speakerNamingPending jobs

Jobs with `.speakerNamingPending` should NOT be auto-removed after `completedJobLifetime`.

**Files:**
- Modify: `app/MeetingTranscriber/Sources/PipelineQueue.swift:183-192`

**Step 1: Write the failing test**

```swift
func testSpeakerNamingPendingJobNotAutoRemoved() async throws {
    let queue = PipelineQueue(logDir: tmpDir, completedJobLifetime: 1)
    let job = PipelineJob(
        meetingTitle: "Test",
        appName: "App",
        mixPath: tmpDir.appendingPathComponent("mix.wav"),
        appPath: nil,
        micPath: nil,
        micDelay: 0,
    )
    queue.jobs.append(job)
    queue.updateJobState(id: job.id, to: .speakerNamingPending)

    try await Task.sleep(for: .seconds(2))

    XCTAssertNotNil(queue.jobs.first { $0.id == job.id })
}
```

**Step 2: Guard auto-removal**

In `updateJobState`, the auto-removal only fires for `.done`:

```swift
if newState == .done {
    Task { [weak self] in
        try? await Task.sleep(for: .seconds(self?.completedJobLifetime ?? 60))
        self?.removeJob(id: id)
    }
}
// .speakerNamingPending: no auto-removal — user decides
```

**Step 3: Run tests**

Run: `cd app/MeetingTranscriber && swift test`
Expected: All pass

**Step 4: Commit**

```bash
git add app/MeetingTranscriber/Sources/PipelineQueue.swift app/MeetingTranscriber/Tests/PipelineQueueTests.swift
git commit -m "fix(app): prevent auto-removal of jobs awaiting speaker naming"
```

---

## Task 9: Load naming data from disk on snapshot restore

When the app starts, `loadSnapshot()` must rebuild the RAM cache from `_naming.json` sidecar files for all `.speakerNamingPending` jobs.

**Files:**
- Modify: `app/MeetingTranscriber/Sources/PipelineQueue.swift` (loadSnapshot)

**Step 1: Write the failing test**

```swift
func testLoadSnapshotRebuildsSpeakerNamingCache() throws {
    // Simulate a previous session: job in speakerNamingPending + naming JSON on disk
    let outputDir = tmpDir.appendingPathComponent("output")
    let recordingsDir = outputDir.appendingPathComponent("recordings")
    try FileManager.default.createDirectory(at: recordingsDir, withIntermediateDirectories: true)

    let slug = "test_meeting"
    let jobID = UUID()
    let namingData = PipelineQueue.SpeakerNamingData(
        jobID: jobID,
        meetingTitle: "Test Meeting",
        mapping: ["SPEAKER_0": "Alice"],
        speakingTimes: ["SPEAKER_0": 60.0],
        embeddings: ["SPEAKER_0": [0.1, 0.2]],
        audioPath: recordingsDir.appendingPathComponent("\(slug)_16k.wav"),
        segments: [.init(start: 0, end: 5, speaker: "SPEAKER_0")],
        participants: [],
        isDualSource: false,
    )
    let json = try JSONEncoder().encode(namingData)
    try json.write(to: recordingsDir.appendingPathComponent("\(slug)_naming.json"))

    // Create job snapshot
    var job = PipelineJob(
        meetingTitle: "Test Meeting",
        appName: "App",
        mixPath: recordingsDir.appendingPathComponent("\(slug)_mix.wav"),
        appPath: nil, micPath: nil, micDelay: 0,
    )
    job.state = .speakerNamingPending
    job.namingSlug = slug
    // Force the job ID to match
    // (In practice, use a helper or make PipelineJob init accept an ID)
    let jobData = try JSONEncoder().encode([job])
    try jobData.write(to: tmpDir.appendingPathComponent("pipeline_queue.json"))

    // Load snapshot in a new queue
    let queue = PipelineQueue(
        engine: MockTranscriptionEngine(),
        diarizationFactory: { MockDiarizer() },
        protocolGeneratorFactory: { nil },
        outputDir: outputDir,
        logDir: tmpDir,
        diarizeEnabled: true,
    )
    queue.loadSnapshot()

    XCTAssertEqual(queue.jobs.first?.state, .speakerNamingPending)
    XCTAssertNotNil(queue.speakerNamingDataByJob[queue.jobs.first!.id])
}
```

**Step 2: Update `loadSnapshot()` to rebuild cache**

```swift
func loadSnapshot() {
    // ... existing loading logic ...

    // Rebuild speaker naming cache from disk
    for job in jobs where job.state == .speakerNamingPending {
        if let slug = job.namingSlug, let data = loadNamingData(slug: slug) {
            speakerNamingDataByJob[job.id] = data
        } else {
            // Naming data lost — transition to done
            logger.warning("Naming data not found for job \(job.id), marking as done")
            if let idx = jobs.firstIndex(where: { $0.id == job.id }) {
                jobs[idx].state = .done
            }
        }
    }
}
```

**Step 3: Run tests**

Run: `cd app/MeetingTranscriber && swift test`
Expected: All pass

**Step 4: Commit**

```bash
git add app/MeetingTranscriber/Sources/PipelineQueue.swift app/MeetingTranscriber/Tests/PipelineQueueTests.swift
git commit -m "feat(app): rebuild speaker naming cache from disk on snapshot restore"
```

---

## Task 10: Auto-cleanup of stale pending naming data (24h)

Prevent unbounded disk growth. Pending items older than 24h are auto-resolved with auto-names.

**Files:**
- Modify: `app/MeetingTranscriber/Sources/PipelineQueue.swift`

**Step 1: Write the failing test**

```swift
func testStalePendingNamingAutoCleanedAfter24h() async throws {
    let queue = PipelineQueue(logDir: tmpDir)
    var job = PipelineJob(
        meetingTitle: "Old Meeting",
        appName: "App",
        mixPath: tmpDir.appendingPathComponent("mix.wav"),
        appPath: nil, micPath: nil, micDelay: 0,
    )
    // Simulate a job enqueued 25 hours ago
    job = PipelineJob(
        meetingTitle: "Old Meeting",
        appName: "App",
        mixPath: tmpDir.appendingPathComponent("mix.wav"),
        appPath: nil, micPath: nil, micDelay: 0,
    )
    job.state = .speakerNamingPending
    queue.jobs.append(job)

    // Job enqueuedAt is now, so cleanupStalePending with maxAge=0 should clean it
    queue.cleanupStalePending(maxAge: 0)

    XCTAssertEqual(queue.jobs.first?.state, .done)
    XCTAssertNil(queue.speakerNamingDataByJob[job.id])
}
```

**Step 2: Implement `cleanupStalePending`**

```swift
/// Auto-resolve pending naming items older than maxAge (default: 24h).
/// Transitions them to .done and deletes sidecar files.
func cleanupStalePending(maxAge: TimeInterval = 86400) {
    let now = Date()
    for job in jobs where job.state == .speakerNamingPending {
        if now.timeIntervalSince(job.enqueuedAt) > maxAge {
            logger.info("Auto-resolving stale pending naming for \(job.meetingTitle)")
            speakerNamingDataByJob.removeValue(forKey: job.id)
            if let slug = job.namingSlug {
                deleteNamingData(slug: slug)
                cleanupSidecarFiles(slug: slug)
            }
            updateJobState(id: job.id, to: .done)
        }
    }
}

/// Delete 16kHz audio and segment sidecar files for a slug.
private func cleanupSidecarFiles(slug: String?) {
    guard let slug, let outputDir else { return }
    let recordingsDir = outputDir.appendingPathComponent("recordings")
    let suffixes = ["_16k.wav", "_app_16k.wav", "_mic_16k.wav", "_segments.json"]
    for suffix in suffixes {
        let path = recordingsDir.appendingPathComponent("\(slug)\(suffix)")
        try? FileManager.default.removeItem(at: path)
    }
}
```

**Step 3: Call on app startup**

In `AppState` or `loadSnapshot()`:

```swift
// After loadSnapshot completes:
cleanupStalePending()
```

**Step 4: Run tests**

Run: `cd app/MeetingTranscriber && swift test`
Expected: All pass

**Step 5: Commit**

```bash
git add app/MeetingTranscriber/Sources/PipelineQueue.swift app/MeetingTranscriber/Tests/PipelineQueueTests.swift
git commit -m "feat(app): auto-cleanup stale pending speaker naming after 24h"
```

---

## Task 11: Multi-meeting naming dialog (meeting picker)

When multiple naming requests are pending, the window should let the user pick which meeting to name.

**Files:**
- Modify: `app/MeetingTranscriber/Sources/MeetingTranscriberApp.swift:112-122`
- Modify: `app/MeetingTranscriber/Sources/AppState.swift`
- Modify: `app/MeetingTranscriber/Sources/PipelineQueue.swift`

**Step 1: Add `selectedNamingJobID` to AppState**

```swift
var selectedNamingJobID: UUID?
```

**Step 2: Add lookup helper to PipelineQueue**

```swift
func speakerNamingData(forJobID jobID: UUID?) -> SpeakerNamingData? {
    if let jobID, let data = speakerNamingDataByJob[jobID] { return data }
    return pendingSpeakerNaming
}
```

**Step 3: Update Window binding**

```swift
Window("Name Speakers", id: "speaker-naming") {
    if let data = appState.pipelineQueue.speakerNamingData(
        forJobID: appState.selectedNamingJobID
    ) {
        VStack(spacing: 0) {
            if appState.pipelineQueue.pendingSpeakerNamingJobs.count > 1 {
                Picker("Meeting", selection: $appState.selectedNamingJobID) {
                    ForEach(appState.pipelineQueue.pendingSpeakerNamingJobs) { job in
                        Text(job.meetingTitle).tag(Optional(job.id))
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)
                .padding(.top, 8)
            }

            SpeakerNamingView(data: data) { result in
                appState.pipelineQueue.completeSpeakerNaming(
                    jobID: data.jobID, result: result,
                )
                if appState.pipelineQueue.pendingSpeakerNamingJobs.isEmpty {
                    closeWindow(id: "speaker-naming")
                } else {
                    // Auto-advance to next pending meeting
                    appState.selectedNamingJobID =
                        appState.pipelineQueue.pendingSpeakerNamingJobs.first?.id
                }
            }
        }
    } else {
        Text("No speaker data available.")
            .padding()
    }
}
```

**Step 4: Run tests**

Run: `cd app/MeetingTranscriber && swift test`
Expected: All pass

**Step 5: Commit**

```bash
git add app/MeetingTranscriber/Sources/MeetingTranscriberApp.swift app/MeetingTranscriber/Sources/AppState.swift app/MeetingTranscriber/Sources/PipelineQueue.swift
git commit -m "feat(app): multi-meeting picker in speaker naming dialog"
```

---

## Task 12: Clean up sidecar files when naming is resolved

When the user confirms or skips naming, delete the `_16k.wav`, `_segments.json`, and `_naming.json` files.

**Files:**
- Modify: `app/MeetingTranscriber/Sources/PipelineQueue.swift`

**Step 1: Write test**

```swift
func testConfirmedNamingCleansUpSidecarFiles() async throws {
    let outputDir = tmpDir.appendingPathComponent("output")
    let recordingsDir = outputDir.appendingPathComponent("recordings")
    try FileManager.default.createDirectory(at: recordingsDir, withIntermediateDirectories: true)

    let slug = "test"
    // Create fake sidecar files
    for suffix in ["_16k.wav", "_naming.json", "_segments.json"] {
        try Data([0]).write(to: recordingsDir.appendingPathComponent("\(slug)\(suffix)"))
    }

    let queue = PipelineQueue(
        engine: MockTranscriptionEngine(),
        diarizationFactory: { MockDiarizer() },
        protocolGeneratorFactory: { nil },
        outputDir: outputDir,
        logDir: tmpDir,
    )
    var job = PipelineJob(
        meetingTitle: "Test", appName: "App",
        mixPath: recordingsDir.appendingPathComponent("\(slug)_mix.wav"),
        appPath: nil, micPath: nil, micDelay: 0,
    )
    job.state = .speakerNamingPending
    job.namingSlug = slug
    queue.jobs.append(job)
    queue.speakerNamingDataByJob[job.id] = PipelineQueue.SpeakerNamingData(
        jobID: job.id, meetingTitle: "Test",
        mapping: [:], speakingTimes: [:], embeddings: [:],
        audioPath: recordingsDir.appendingPathComponent("\(slug)_16k.wav"),
        segments: [], participants: [], isDualSource: false,
    )

    queue.completeSpeakerNaming(jobID: job.id, result: .confirmed([:]))
    try await Task.sleep(for: .seconds(2))

    // All sidecar files should be gone
    for suffix in ["_16k.wav", "_naming.json", "_segments.json"] {
        let path = recordingsDir.appendingPathComponent("\(slug)\(suffix)")
        XCTAssertFalse(FileManager.default.fileExists(atPath: path.path),
                       "\(suffix) should be cleaned up")
    }
    // Original recordings should remain
}
```

**Step 2: Verify `cleanupSidecarFiles` is called in all resolution paths**

- `reapplySpeakerNames` (confirmed) — already calls cleanup at end
- `handleLateNaming(.skipped)` — already calls cleanup
- `handleLateNaming(.rerun)` — does NOT cleanup (re-diarization needs the files)
- `cleanupStalePending` — already calls cleanup

**Step 3: Run tests**

Run: `cd app/MeetingTranscriber && swift test`
Expected: All pass

**Step 4: Commit**

```bash
git add app/MeetingTranscriber/Sources/PipelineQueue.swift app/MeetingTranscriber/Tests/PipelineQueueTests.swift
git commit -m "fix(app): clean up sidecar files after speaker naming resolved"
```

---

## Task 13: Update existing tests

Some existing tests may need adjustment due to the refactored API.

**Files:**
- Modify: `app/MeetingTranscriber/Tests/PipelineQueueTests.swift`
- Modify: `app/MeetingTranscriber/Tests/WorkflowIntegrationTests.swift`
- Modify: `app/MeetingTranscriber/Tests/WatchLoopE2ETests.swift`

**Step 1: Audit all existing test references to `pendingSpeakerNaming` and `completeSpeakerNaming`**

The `speakerNamingHandler` API is unchanged, so most tests should pass. Fix any that reference the old single-property API directly.

**Step 2: Run full test suite**

Run: `cd app/MeetingTranscriber && swift test`
Expected: All pass

**Step 3: Run lint**

Run: `./scripts/lint.sh`
Expected: No errors

**Step 4: Commit**

```bash
git add app/MeetingTranscriber/Tests/
git commit -m "test(app): update tests for re-openable speaker naming dialog"
```

---

## Summary

| Task | What | Effort |
|------|------|--------|
| 1 | Add `speakerNamingPending` job state | Small |
| 2 | Make `SpeakerNamingData` Codable, persist to disk as sidecar JSON | Medium |
| 3 | Persist 16kHz audio + transcript segments for re-diarization | Medium |
| 4 | Replace timeout with non-blocking flow (keeps data on disk) | Medium |
| 5 | Show button based on pending naming jobs | Small |
| 6 | Late re-apply speaker names (confirmed) + protocol re-gen | Medium |
| 7 | Late re-diarization with different speaker count | Medium |
| 8 | Prevent auto-removal of pending jobs | Small |
| 9 | Load naming data from disk on snapshot restore | Medium |
| 10 | Auto-cleanup stale pending after 24h | Small |
| 11 | Multi-meeting naming dialog (picker) | Medium |
| 12 | Clean up sidecar files when resolved | Small |
| 13 | Update existing tests | Small |

### Data flow

```
Pipeline completes with timeout/skip
  → naming data saved to recordings/{slug}_naming.json  (disk = truth)
  → 16kHz audio saved to recordings/{slug}_16k.wav
  → segments saved to recordings/{slug}_segments.json
  → job state = .speakerNamingPending
  → RAM cache populated from disk

App restart
  → loadSnapshot() loads jobs
  → for each .speakerNamingPending job: load _naming.json → RAM cache
  → cleanupStalePending() removes items > 24h

User opens dialog + confirms
  → reapplySpeakerNames() rewrites transcript + protocol
  → cleanup: delete _naming.json, _16k.wav, _segments.json
  → job state = .done

User opens dialog + re-runs
  → lateDiarization() loads _16k.wav, runs diarization
  → new naming data saved to disk
  → dialog re-opens with fresh results
```

Total: ~13 tasks, moderate complexity. The hardest parts are Task 4 (continuation refactor), Task 6 (late re-apply), and Task 7 (late re-diarization).
