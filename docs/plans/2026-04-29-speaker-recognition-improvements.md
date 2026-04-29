# Speaker Recognition Improvements — Analysis & Recommendations

**Date:** 2026-04-29
**Context:** Discussion about improving speaker recognition: a name picker, and suggestions from previously recognized speakers.

---

## Part 1: Status quo in code

### SpeakerMatcher (`app/MeetingTranscriber/Sources/SpeakerMatcher.swift`)

- Cosine distance threshold `0.40`, confidence margin `0.10`, max 5 embeddings per speaker (FIFO)
- Persisted in `speakers.json`, match via `min(distance)` across all embeddings (lines 84–86)
- Threshold is **configurable** via constructor (line 45)
- `preMatchParticipants()` (lines 162–194) auto-assigns participants — but only when speaker count exactly matches participant count
- Migration logic for legacy single-embedding format (lines 10–21)

### FluidDiarizer (`app/MeetingTranscriber/Sources/FluidDiarizer.swift`)

- **Offline mode** (`.offlineDiarizer`): wraps FluidAudio's `OfflineDiarizerManager`, extracts embeddings via `fluidResult.speakerDatabase` (line 169)
- **Sortformer mode**: `SortformerDiarizer` (lines 76–101), HuggingFace models, same `speakerDatabase` field
- Both modes return embeddings keyed by speaker ID in `DiarizationResult.embeddings`
- **Limitation:** no embedding quality filtering, no minimum segment duration

### SpeakerNamingView (`app/MeetingTranscriber/Sources/SpeakerNamingView.swift`)

- Free-text input via `AccessibleTextField` (lines 207–211)
- **Quick-pick buttons** for unused participants (lines 213–224)
- `unusedParticipants()` (lines 284–286) filters out names already assigned
- Auto-naming display: "Auto: {autoName}" or "Unknown" (lines 196–204)
- Audio playback of longest segment per speaker (lines 231–281)
- Re-run via stepper for speaker count (lines 113–128)

### PipelineQueue speaker naming flow (`app/MeetingTranscriber/Sources/PipelineQueue.swift`)

1. After diarization: builds `SpeakerNamingData` (lines 403–412) with mapping from `SpeakerMatcher.match()` (line 391)
2. Posts `.showSpeakerNaming` notification (line 428)
3. Awaits user input via `CheckedContinuation` with 120s timeout (lines 420–432)
4. Updates DB via `matcher.updateDB()` (line 440) after confirmation

### ParticipantReader (`app/MeetingTranscriber/Sources/ParticipantReader.swift`)

Reads Teams roster via Accessibility:
1. Known panel IDs (line 32): "roster-list", "people-pane"
2. AX container scan (line 44): `AXList`/`AXTable` with 2+ rows
3. Window title parsing (line 72): "Name1, Name2 | Microsoft Teams"

Returns `[String]?` → flows into `PipelineQueue` job (line 251) → `SpeakerNamingData` (line 411) → quick-pick buttons.

### speakers.json schema

```json
[
  { "name": "Roman", "embeddings": [[...384 floats...], [...], ...] },
  { "name": "Anna", "embeddings": [[...], ...] }
]
```

- Array of `StoredSpeaker` objects
- Up to 5 embeddings (FIFO via `removeFirst()`)
- Backward-compatible with legacy `"embedding"` key (single embedding)

---

## Part 2: Weak spots for recognition quality

| Problem | Fix |
|---|---|
| Embeddings stored unfiltered (even from 0.5s segments) | Minimum segment duration (e.g. 3s) before storing |
| Match uses `min(distance)` — a single outlier is enough | Also compute centroid/mean, or use k-NN voting |
| Threshold `0.40` is global and fixed | Per-speaker adaptive: stricter as embedding count grows |
| FIFO drops old embeddings even if higher quality | Quality score (segment duration × SNR) instead of FIFO eviction |
| `preMatchParticipants` only fires when speaker count == participant count | Greedy match by speaking time even on mismatch (with confidence) |
| No cross-check between app and mic tracks | Merge `M_0` and `R_1` if embeddings are similar (same person, both tracks) |
| Confidence margin fixed at `0.10` | Small margin can cause false positives |
| Known names from `speakers.json` not surfaced as picker suggestions | Add `allSpeakerNames()` as second suggestion row in `SpeakerNamingView` |
| No UI to manage speaker DB (rename / delete / merge) | Settings tab "Known Voices" |

---

## Part 3: How others do it

### Otter.ai (~85% accuracy after training)

- Tagging during meetings trains the profile — every manual assignment becomes a learning sample
- **Audio import** of past conversations for faster cold-start enrollment
- Profiles can be shared in workspaces
- Best practice: clear, close-up audio

### Microsoft Teams (two enrollment modes)

- **Automatic:** profile builds passively across multiple meetings
- **Manual:** user reads 5–10 short phrases → profile ready immediately
- Encrypted tenant storage
- Voiceprint analyzes pitch, tone, speaking style

### Fireflies.ai (~95% with optimal audio)

- Zoom/Meet/Teams: shows **actual participant names** from platform API
- Otherwise just "Speaker 1, 2, 3"
- Up to 50 speakers, 100+ languages
- ML models trained on millions of hours of conversational data

### Granola (negative example)

- **No diarization at all**
- Frequently called out as a major weakness in reviews
- Confirms: speaker recognition is a competitive advantage

### tl;dv

- Speaker recognition + timestamps + video recording
- Preferred over Granola for clarity and collaboration

### pyannote.ai voiceprints — best practices

- **Exactly one voiceprint per person** (don't merge multiple → drift)
- **Target speaker only**, no overlaps in the sample
- **Max 30 seconds** sample length — more does not help
- Language-agnostic (embedding doesn't depend on content)
- 2.8% EER on VoxCeleb 1 with plain cosine distance

### NVIDIA NeMo pipeline

- VAD (MarbleNet) → TitaNet embeddings → clustering
- VAD tuning is **critical** — bad segment boundaries pollute embeddings
- Onset/offset thresholds + padding control sensitivity

---

## Part 4: Three industry patterns

1. **Passive learning + active enrollment option** (Otter, Teams)
2. **Platform participant lists as ground truth** (Fireflies)
3. **Quality gates on embeddings** (pyannote, NeMo)

---

## Part 5: Concrete roadmap

### App's USP

Local-first (CoreML/ANE) — a real advantage over Otter/Fireflies/Teams, which are all cloud-based. Pyannote workflow runs locally too, but lacks an auto-enrollment UI.

### Recommendation in order

#### 1. Extend speaker picker with historical names (smallest diff, biggest UX gain)

- In `SpeakerNamingView`, in addition to meeting participants, surface all `matcher.allSpeakerNames()` as a second button row ("Known voices") or as a combobox/autocomplete
- On click: assign the name + add the new embedding to the existing speaker → recognition improves over time
- API extension in `SpeakerMatcher`: new method `allSpeakerNames() -> [String]`
- Touches only `SpeakerNamingView.swift` + small API change in `SpeakerMatcher.swift`

#### 2. Active enrollment in Settings ("Set up voice")

- Like Teams manual mode: user reads ~30s of prepared text
- Produces a high-quality centroid embedding immediately, no need to wait for meetings
- Solves the cold-start problem
- New view `VoiceEnrollmentView`, mounted in `SettingsView`

#### 3. Embedding quality filter (pyannote-style)

- Minimum speaking time (e.g. 3s per speaker) before storing an embedding
- Centroid instead of 5-FIFO pool (one is enough if clean)
- Overlap detection — discard embeddings from overlap regions
- Changes primarily in `PipelineQueue.swift` (line 391) and `SpeakerMatcher.updateDB`

#### 4. Settings tab "Known voices"

- List all `StoredSpeaker` entries with name + embedding count
- Actions: rename / delete / merge / re-enroll
- Optional: sample audio per speaker (if available)

#### 5. Adaptive threshold

- Per speaker: stricter with few embeddings, looser with many
- Confidence margin scaled by embedding count

---

## Sources

- [Otter Speaker Identification Overview](https://help.otter.ai/hc/en-us/articles/21665587209367-Speaker-Identification-Overview)
- [Otter Best Practices for Speaker Identification](https://help.otter.ai/hc/en-us/articles/37817248501783-Best-Practices-to-Maximize-Speaker-Identification)
- [Microsoft Teams Voice and Face Enrollment](https://learn.microsoft.com/en-us/microsoftteams/rooms/voice-and-face-recognition)
- [Microsoft Teams Voice Recognition Configuration](https://learn.microsoft.com/en-us/microsoftteams/rooms/voice-recognition)
- [Fireflies Speaker Diarization Review](https://summarizemeeting.com/en/app-reviews/fireflies-speaker-diarization)
- [Granola AI Review (no speaker ID)](https://tldv.io/blog/granola-review/)
- [pyannote.ai Voiceprint Tutorial](https://docs.pyannote.ai/tutorials/identification-with-voiceprints)
- [pyannote/embedding Model Card](https://huggingface.co/pyannote/embedding)
- [NVIDIA NeMo Speaker Diarization](https://docs.nvidia.com/nemo-framework/user-guide/latest/nemotoolkit/asr/speaker_diarization/intro.html)
- [NeMo Diarization Tuning Deep Dive](https://lajavaness.medium.com/deep-dive-into-nemo-how-to-efficiently-tune-a-speaker-diarization-pipeline-d6de291302bf)
