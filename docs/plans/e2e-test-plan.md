# E2E Test Plan: Full Pipeline Test

## Summary

Make `WatchLoop.handleMeeting()` testable via protocol-based dependency injection, then test the complete pipeline: detect → record → transcribe → diarize → protocol.

## Refactoring: 3 Protocols + Injection

### 1. `RecordingProvider` protocol (add to DualSourceRecorder.swift)

```swift
protocol RecordingProvider {
    func start(appPID: pid_t, noMic: Bool, micDeviceUID: String?) throws
    func stop() throws -> RecordingResult
}

extension DualSourceRecorder: RecordingProvider {}
```

### 2. `DiarizationProvider` protocol (add to DiarizationProcess.swift)

```swift
protocol DiarizationProvider {
    var isAvailable: Bool { get }
    func run(audioPath: URL, numSpeakers: Int?, meetingTitle: String) async throws -> DiarizationResult
}

extension DiarizationProcess: DiarizationProvider {
    func run(audioPath: URL, numSpeakers: Int?, meetingTitle: String) async throws -> DiarizationResult {
        try await run(audioPath: audioPath, numSpeakers: numSpeakers, expectedNames: [], speakersDB: nil, meetingTitle: meetingTitle)
    }
}
```

### 3. `ProtocolGenerating` protocol (add to ProtocolGenerator.swift)

```swift
protocol ProtocolGenerating {
    func generate(transcript: String, title: String, diarized: Bool, claudeBin: String) async throws -> String
}

struct DefaultProtocolGenerator: ProtocolGenerating {
    func generate(transcript: String, title: String, diarized: Bool, claudeBin: String) async throws -> String {
        try await ProtocolGenerator.generate(transcript: transcript, title: title, diarized: diarized, claudeBin: claudeBin)
    }
}
```

### 4. Modify WatchLoop.swift

Add 3 injectable properties with defaults:

```swift
let recorderFactory: () -> RecordingProvider
let diarizationFactory: () -> DiarizationProvider
let protocolGenerator: ProtocolGenerating
```

Update init (defaults preserve backward compatibility):
```swift
recorderFactory: @escaping () -> RecordingProvider = { DualSourceRecorder() },
diarizationFactory: @escaping () -> DiarizationProvider = { DiarizationProcess() },
protocolGenerator: ProtocolGenerating = DefaultProtocolGenerator(),
```

Change 3 lines in `handleMeeting()`:
- `let recorder = DualSourceRecorder()` → `let recorder = recorderFactory()`
- `let diarizeProcess = DiarizationProcess()` → `let diarizeProcess = diarizationFactory()`
- `ProtocolGenerator.generate(...)` → `protocolGenerator.generate(...)`

Make `handleMeeting()` internal (remove `private`).

## Mock vs Real Decision

| Component | Decision | Rationale |
|-----------|----------|-----------|
| MeetingDetector | MOCK | Injectable `windowListProvider` |
| DualSourceRecorder | MOCK | Needs real PID + audiotap. Return fixture WAVs as RecordingResult |
| WhisperKit | REAL | Core quality gate. Catches sample rate + token bugs |
| DiarizationProcess | MOCK (fast tests) + REAL (slow test) | Fast tests mock for speed. Slow test runs real pyannote to verify end-to-end diarization. Skips if .venv/HF_TOKEN unavailable. |
| ProtocolGenerator | MOCK | Claude CLI expensive/slow. Return canned Markdown |

## Test Audio

Use existing `tests/fixtures/two_speakers_de.wav`. Upsample to 48kHz in test setup to simulate DualSourceRecorder output. The 48kHz→16kHz resample path in `handleMeeting()` is exercised.

For dual-source test: split fixture in half (first half = app, second half = mic).

## Tests (Tests/WatchLoopE2ETests.swift)

### 1. `testFullPipelineDetectRecordTranscribeDiarizeProtocol`
- Mock recorder returns 48kHz fixture WAV
- Mock diarization returns known speaker segments
- Mock protocol gen captures transcript
- REAL WhisperKit transcribes
- **Asserts:** All state transitions, diarization called, speaker labels in transcript, no Whisper tokens, timestamp format, .txt + .md files saved, protocol contains header + transcript

### 2. `testDualSourceTranscriptionPath`
- Split fixture into app + mic WAVs
- **Asserts:** Transcript contains "Remote" (app) and "Roman" (mic label)

### 3. `testEmptyTranscriptTransitionsToError`
- Feed 1s of silence
- **Asserts:** state == .error, lastError == "Empty transcript", protocol gen NOT called

### 4. `testDiarizationSkippedWhenNotAvailable`
- diarizeEnabled=true but isAvailable=false
- **Asserts:** Pipeline completes, diarization NOT called, protocol still generated

### 5. `testCooldownPreventsRedetectionAfterHandling`
- detect → reset(appName:) → checkOnce() == nil

### 6. `testResamplePathProduces16kHzForWhisperKit`
- Create 48kHz WAV, resample, verify file header, verify WhisperKit transcribes it

### 7. `testFullPipelineWithRealDiarization` (slow)
- Skip if `!DiarizationProcess().isAvailable` or no HF_TOKEN in Keychain
- Mock recorder returns 48kHz fixture WAV
- REAL DiarizationProcess runs pyannote via .venv/bin/python + tools/diarize/diarize.py
- REAL WhisperKit transcribes
- Mock protocol gen captures transcript
- **Asserts:** Diarization returns segments, speaker labels assigned, transcript contains SPEAKER_ labels

## Bug Regression Coverage

| Bug | Test |
|-----|------|
| 48kHz → WhisperKit (needs 16kHz) | testResamplePathProduces16kHzForWhisperKit |
| Whisper special tokens in output | testFullPipeline: `!contains("<\|")` |
| Empty transcript | testEmptyTranscriptTransitionsToError |
| Diarization silently skipped | testDiarizationSkippedWhenNotAvailable |
| Speaker labels missing | testFullPipeline: `contains("SPEAKER_")` |
| Meeting re-detection | testCooldownPreventsRedetectionAfterHandling |

## Implementation Sequence

1. Add `RecordingProvider` protocol to DualSourceRecorder.swift (8 lines)
2. Add `DiarizationProvider` protocol to DiarizationProcess.swift (12 lines)
3. Add `ProtocolGenerating` protocol to ProtocolGenerator.swift (15 lines)
4. Modify WatchLoop.swift: 3 properties + init params + 3 line changes + make handleMeeting internal
5. Create Tests/WatchLoopE2ETests.swift (~350 lines)
6. Run tests, verify all pass

## Notes

- Tests skip in CI (`XCTSkipIf(ProcessInfo.processInfo.environment["CI"] != nil)`)
- WhisperKit uses `openai_whisper-small` for speed (not large-v3-turbo)
- First run downloads model (~30-60s), subsequent runs cached (~20-30s)
- `DualSourceRecorder.recordingsDir` must exist for intermediate 16kHz files — create in setUp
- `ParticipantReader.readParticipants(pid: 9999)` returns nil (mock PID) — correct path
