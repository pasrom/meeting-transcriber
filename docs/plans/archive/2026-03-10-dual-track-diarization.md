# Dual-Track Diarization

## Problem

Currently FluidAudio diarizes the **mix** (app + mic combined). This causes:

1. **Without headphones:** Mic picks up speaker output → FluidAudio sees the same voice on both tracks → mic speaker identification via temporal overlap becomes unreliable (matched "Teams" as a speaker)
2. **Speaker count underestimated:** Mix contains overlapping audio from both tracks → FluidAudio's clustering merges speakers that appear on both tracks
3. **Assumption "mic = one speaker" is wrong:** In a conference room, multiple local people share one mic

## Solution: Diarize App and Mic Tracks Separately

```
Current:
  app + mic → mix → diarize(mix) → identifyMicSpeaker() → assignSpeakersHybrid()

Proposed:
  app_16k → diarize(app) → remote speakers (R0, R1, ...)
  mic_16k → diarize(mic) → local speakers  (M0, M1, ...)
            ↓
  cross-track embedding match → unified speaker names
            ↓
  assignSpeakersDualTrack() → final labeled transcript
```

Benefits:
- App track is clean (only remote audio, no echo)
- Mic track has only local speakers (no remote bleed with headphones, some bleed without — but FluidAudio handles that better than the overlap heuristic)
- `identifyMicSpeaker()` becomes unnecessary
- Speaker count per track is naturally smaller → FluidAudio estimates better
- Multiple local speakers supported

## Changes

### Step 1: Dual diarization in PipelineQueue

**File:** `PipelineQueue.swift`

In `processNext()`, replace the single diarization call with two:

```swift
// Before:
diarization = try await diarizeProcess.run(audioPath: mix16k, ...)

// After (dual-source):
let appDiarization = try await diarizeProcess.run(audioPath: app16k, ...)
let micDiarization = try await diarizeProcess.run(audioPath: mic16k, ...)
```

- app_16k and mic_16k are already created (lines 204-208)
- Single-source fallback: keep diarizing mix16k when appPath/micPath unavailable
- Run sequentially (FluidAudio caches models, second run is fast)

Prefix speaker IDs to avoid collisions: `R_SPEAKER_0`, `M_SPEAKER_0`.

### Step 2: Merge diarization results

**File:** `DiarizationProcess.swift`

New method:

```swift
static func mergeDualTrackDiarization(
    appDiarization: DiarizationResult,
    micDiarization: DiarizationResult
) -> DiarizationResult
```

- Prefix app speaker IDs with `R_` and mic with `M_`
- Merge segments (sorted by time)
- Merge speakingTimes
- Merge embeddings (prefixed keys)
- No cross-track deduplication needed — remote and local speakers are distinct

### Step 3: Cross-track speaker matching (optional, for no-headphone case)

**File:** `SpeakerMatcher.swift`

When mic picks up remote speakers (no headphones), the same person may appear in both diarizations. Optional: compare embeddings across tracks via cosine similarity and merge if close enough.

This is a refinement — skip for first iteration. Without headphones, local and remote speakers will just get separate names, which the user can correct in the naming dialog.

### Step 4: New assignSpeakersDualTrack

**File:** `DiarizationProcess.swift`

```swift
static func assignSpeakersDualTrack(
    appSegments: [TimestampedSegment],
    micSegments: [TimestampedSegment],
    appDiarization: DiarizationResult,
    micDiarization: DiarizationResult
) -> [TimestampedSegment]
```

- App transcript segments → match against `appDiarization` (by temporal overlap)
- Mic transcript segments → match against `micDiarization` (by temporal overlap)
- Merge and sort by time
- Simpler than current `assignSpeakersHybrid` — no mic speaker exclusion logic needed

### Step 5: Update SpeakerNaming data

**File:** `PipelineQueue.swift`

`SpeakerNamingData` gets both sets of embeddings merged. The naming dialog shows all speakers (remote + local) with their speaking times. No "locked" mic speaker concept — all rows are editable (already done in previous commit).

### Step 6: Remove identifyMicSpeaker

**File:** `DiarizationProcess.swift`

Delete `identifyMicSpeaker()` — no longer needed. Remove all references in PipelineQueue.

### Step 7: Update speaker count hints

**File:** `PipelineQueue.swift`

When participants are available from Teams:
- App diarization: `numSpeakers = participants.count` (remote speakers)
- Mic diarization: `numSpeakers = nil` (auto-detect, usually 1-3 local)

When no participants: both auto-detect.

### Step 8: Single-source fallback

When only mixPath available (no separate app/mic tracks):
- Keep current behavior: diarize mix, use `assignSpeakers()`
- No hybrid logic needed

## Tests

### Existing tests to update

| Test | Change |
|------|--------|
| `DiarizationProcessTests.testIdentifyMicSpeaker*` (3 tests) | Delete |
| `DiarizationProcessTests.testAssignSpeakersHybrid*` (3 tests) | Replace with dual-track tests |
| `WatchLoopE2ETests.testDualSourceTranscriptionPath` | Update for dual diarization |
| `WatchLoopE2ETests.testSpeakerIdentificationWithDualSource` | Rewrite without identifyMicSpeaker |

### New tests

| Test | Verifies |
|------|----------|
| `testMergeDualTrackDiarization` | Segments merged, IDs prefixed, embeddings merged |
| `testAssignSpeakersDualTrack` | App segments get app diarization names, mic segments get mic names |
| `testDualTrackWithOverlappingSpeakers` | Simultaneous speech across tracks |
| `testSingleSourceFallback` | Mix diarization still works when no separate tracks |
| `testDualTrackNamingShowsAllSpeakers` | Naming dialog shows remote + local speakers |

## Effort Estimate

| Step | Files | Lines |
|------|-------|-------|
| 1. Dual diarization calls | PipelineQueue.swift | ~30 |
| 2. Merge diarization results | DiarizationProcess.swift | ~40 |
| 3. Cross-track matching | (skip first iteration) | — |
| 4. assignSpeakersDualTrack | DiarizationProcess.swift | ~40 |
| 5. Update naming data | PipelineQueue.swift | ~20 |
| 6. Remove identifyMicSpeaker | DiarizationProcess.swift, PipelineQueue.swift | -50 |
| 7. Speaker count hints | PipelineQueue.swift | ~10 |
| 8. Single-source fallback | PipelineQueue.swift | ~10 |
| Tests | Tests/ | ~200 |
| **Total** | | **~300 net lines** |

## Open Questions

1. **Sequential vs parallel diarization?** FluidAudio uses CoreML/ANE — running two instances in parallel may compete for hardware. Sequential is safer, adds ~5s per meeting.
2. **Cross-track speaker dedup (Step 3)?** Worth doing in first iteration, or let users fix in naming dialog?
3. **Min speakers for mic track?** Default 1 or auto-detect? Conference room scenario suggests auto-detect.
