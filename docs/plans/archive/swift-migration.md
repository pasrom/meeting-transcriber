# Migration Plan: Hybrid Swift + Python (Diarization only)

## Goal

Move everything to Swift except speaker diarization. Python stays as a small
venv (~50 MB) containing only pyannote-audio + torch (CPU). The Swift app calls
it via subprocess when diarization is requested.

**Result:**
- App bundle: ~100 MB (vs ~300 MB today)
- Code signing: ~10 binaries (vs ~3000 today)
- No more full pip install in build script
- Notarization becomes trivial
- Python CLI stays for Windows users

## Architecture (After Migration)

```
MeetingTranscriber.app (Swift)
  Contents/
    MacOS/
      MeetingTranscriber        # Swift menu bar app
    Resources/
      audiotap                  # App audio capture (already Swift)
      whisperkit-model/         # CoreML Whisper model (~40 MB)
      python-diarize/           # [optional] small Python venv
        bin/python3
        diarize.py              # Standalone diarization script
        lib/.../pyannote/
        lib/.../torch/
```

```
Swift App Pipeline:
  CGWindowList (meeting detection)
  → AVAudioEngine + audiotap (recording)
  → WhisperKit (transcription, CoreML/ANE)
  → Process + claude CLI (protocol generation)
  → [optional] python-diarize subprocess (speaker labels)
```

## IPC Interfaces (Simplified Post-Migration)

After migration, most IPC files are eliminated. Only diarization IPC remains:

| File | Direction | Remains? | Purpose |
|------|-----------|----------|---------|
| `status.json` | Internal | **Removed** — state is native Swift | — |
| `windows.json` | Internal | **Removed** — detection is native Swift | — |
| `watcher.pid` | Internal | **Removed** — no Python watcher | — |
| `transcriber.log` | Internal | **Removed** — use os_log | — |
| `participants.json` | Swift internal | **Kept** — AX API results for diarize | Same format |
| `speaker_request.json` | Python→Swift | **Kept** — diarize asks for names | Same format |
| `speaker_response.json` | Swift→Python | **Kept** — user provides names | Same format |
| `speaker_count_request.json` | Python→Swift | **Kept** — diarize asks count | Same format |
| `speaker_count_response.json` | Swift→Python | **Kept** — user provides count | Same format |
| `speakers.json` | Python | **Kept** — speaker embedding DB | Same format |

---

## Phase 1: Meeting Detection (Native Swift)

**Duration:** 3 days
**Goal:** Replace Python detector + patterns with native Swift. Remove WindowListWriter IPC.

### Task 1.1: MeetingPatterns.swift

Port `patterns.py` to Swift struct.

```swift
// New file: app/MeetingTranscriber/Sources/MeetingPatterns.swift

struct AppMeetingPattern: Sendable {
    let appName: String
    let ownerNames: [String]
    let meetingPatterns: [String]    // regex strings
    let idlePatterns: [String]       // regex strings
    let minWindowWidth: CGFloat = 200
    let minWindowHeight: CGFloat = 200
}

extension AppMeetingPattern {
    static let teams = AppMeetingPattern(
        appName: "Microsoft Teams",
        ownerNames: ["Microsoft Teams", "Microsoft Teams (work or school)"],
        meetingPatterns: [#".+\s+\|\s+Microsoft Teams"#],
        idlePatterns: [
            #"^Microsoft Teams$"#,
            #"^\s*$"#,
            #"^Microsoft Teams Notification$"#
        ]
    )

    static let zoom = AppMeetingPattern(
        appName: "zoom.us",
        ownerNames: ["zoom.us"],
        meetingPatterns: [#"^Zoom Meeting$"#, #"^Zoom Webinar$"#, #".+\s*-\s*Zoom$"#],
        idlePatterns: [#"^Zoom$"#, #"^Zoom Workplace$"#]
    )

    static let webex = AppMeetingPattern(
        appName: "Webex",
        ownerNames: ["Webex", "Cisco Webex Meetings"],
        meetingPatterns: [#".+\s*-\s*Webex$"#, #"^Meeting \|"#, #".+'s Personal Room"#],
        idlePatterns: [#"^Webex$"#]
    )

    static let all = [teams, zoom, webex]
}
```

### Task 1.2: MeetingDetector.swift

Port `detector.py` to Swift. Use CGWindowListCopyWindowInfo directly (no IPC).

```swift
// New file: app/MeetingTranscriber/Sources/MeetingDetector.swift

struct DetectedMeeting {
    let pattern: AppMeetingPattern
    let windowTitle: String
    let ownerName: String
    let windowPID: pid_t
    let detectedAt: Date
}

@Observable
class MeetingDetector {
    private let patterns: [AppMeetingPattern]
    private let confirmationCount: Int  // default 2
    private var consecutiveHits: [String: Int] = [:]  // keyed by appName

    func checkOnce() -> DetectedMeeting?
    // 1. CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID)
    // 2. For each window dict:
    //    - Get kCGWindowOwnerName, kCGWindowName, kCGWindowBounds, kCGWindowOwnerPID
    //    - Match against patterns (owner name, min size, idle filter, meeting regex)
    // 3. Track consecutive hits per app
    // 4. Return DetectedMeeting after confirmationCount consecutive hits

    func isMeetingActive(_ meeting: DetectedMeeting) -> Bool
    // Check if window with same PID and matching title still exists

    func reset()
    // Clear consecutiveHits
}
```

### Task 1.3: Remove WindowListWriter

- Delete `WindowListWriter.swift`
- Remove WindowListWriter from `MeetingTranscriberApp.swift`
- Remove `WINDOWS_FILE` from Python config (no longer used by app)
- Remove `_get_windows_from_ipc()` from Python detector (keep `_get_windows_from_quartz()` for CLI)

### Task 1.4: Tests

Port `test_watch_detector.py` to Swift:

```swift
// New file: app/MeetingTranscriber/Tests/MeetingDetectorTests.swift

// Test pattern matching:
// - Teams meeting title matches
// - Zoom meeting title matches
// - Webex meeting title matches
// - Idle windows filtered out
// - Min size filter works
// - Confirmation count requires N consecutive hits
// - reset() clears state
```

### Verification
- `cd app/MeetingTranscriber && swift test`
- Manual: Start Teams meeting, verify MeetingDetector.checkOnce() returns DetectedMeeting

---

## Phase 2: Mute Detection (Native Swift)

**Duration:** 2 days
**Goal:** Port Teams mute button and participant reading from AX API to Swift.

### Task 2.1: MuteDetector.swift

Port `mute_detector.py` to Swift.

```swift
// New file: app/MeetingTranscriber/Sources/MuteDetector.swift

struct MuteTransition {
    let timestamp: TimeInterval  // ProcessInfo.processInfo.systemUptime
    let isMuted: Bool
}

@Observable
class MuteDetector {
    private(set) var timeline: [MuteTransition] = []
    private(set) var isActive = false
    private let teamsPID: pid_t
    private let pollInterval: TimeInterval  // default 0.5
    private var task: Task<Void, Never>?

    func start()
    // Check AXIsProcessTrusted()
    // Start async task polling readMuteState() every pollInterval
    // Record transitions to timeline

    func stop()
    // Cancel task

    private func readMuteState() -> Bool?
    // AXUIElementCreateApplication(teamsPID)
    // Search for button with AXDescription starting with:
    //   "unmute" / "stummschaltung aufheben" → muted = true
    //   "mute" / "stummschalten" → muted = false
}
```

### Task 2.2: ParticipantReader.swift

Port `read_participants()` and `write_participants()` to Swift.

```swift
// New file: app/MeetingTranscriber/Sources/ParticipantReader.swift

struct ParticipantReader {
    static func readParticipants(pid: pid_t) -> [String]?
    // 3 strategies (same as Python):
    // 1. Search by AX identifier ("roster-list", "people-pane", etc.)
    // 2. Find AXList/AXTable containers with text rows
    // 3. Parse window title for "Meeting with X, Y, Z"

    static func writeParticipants(_ names: [String], meetingTitle: String = "")
    // Write to ~/.meeting-transcriber/participants.json
    // Format: {"version": 1, "meeting_title": "", "participants": [...]}
    // Atomic write (write .tmp, rename)
}
```

### Task 2.3: Tests

```swift
// New file: app/MeetingTranscriber/Tests/MuteDetectorTests.swift
// - Mock AXUIElement responses
// - Verify timeline recording
// - Test German and English button labels

// New file: app/MeetingTranscriber/Tests/ParticipantReaderTests.swift
// - Test participant name filtering
// - Test JSON write format
```

### Verification
- `cd app/MeetingTranscriber && swift test`
- Manual: Join Teams meeting, verify mute state detection works

---

## Phase 3: Audio Recording (Native Swift)

**Duration:** 1 week
**Goal:** Replace Python sounddevice mic recording with AVAudioEngine. Keep audiotap for app audio.

### Task 3.1: MicRecorder.swift

```swift
// New file: app/MeetingTranscriber/Sources/MicRecorder.swift

import AVFoundation

@Observable
class MicRecorder {
    private var engine: AVAudioEngine?
    private var outputFile: AVAudioFile?

    func start(outputPath: URL, deviceUID: String? = nil) throws
    // 1. Create AVAudioEngine
    // 2. If deviceUID: set input device via AudioObjectSetPropertyData
    // 3. Install tap on inputNode (format: 48kHz mono Float32)
    // 4. Write PCM buffers to WAV file
    // 5. Handle device disconnection (restart on default device change)

    func stop() -> URL
    // Stop engine, close file, return path

    static func listDevices() -> [(uid: String, name: String, channels: Int)]
    // AudioObjectGetPropertyData for all input devices
}
```

### Task 3.2: AudioMixer.swift

Port mixing and echo suppression from Python.

```swift
// New file: app/MeetingTranscriber/Sources/AudioMixer.swift

import Accelerate

struct AudioMixer {
    static func mix(appAudio: URL, micAudio: URL, output: URL,
                    micDelay: TimeInterval = 0,
                    muteTimeline: [MuteTransition] = []) throws
    // 1. Load both WAVs as Float32 arrays
    // 2. Apply mute mask to mic (zero samples during muted periods)
    // 3. Apply echo suppression (RMS gating):
    //    - 20ms windows
    //    - Threshold: 0.01
    //    - Margins: 2 windows before (40ms), 10 windows after (200ms)
    //    - Attenuation: 0.0 (full suppression)
    // 4. Align by micDelay (shift mic samples)
    // 5. Mix: (app + mic) / 2
    // 6. Write to output WAV

    static func resample(_ samples: [Float], from sourceRate: Int, to targetRate: Int) -> [Float]
    // Use vDSP_desamp or Accelerate polyphase resampling
    // Source: 48000 (native) → Target: 16000 (Whisper)
}
```

### Task 3.3: DualSourceRecorder.swift

Orchestrate audiotap + mic recording.

```swift
// New file: app/MeetingTranscriber/Sources/DualSourceRecorder.swift

struct RecordingResult {
    let mixPath: URL
    let appPath: URL?
    let micPath: URL?
    let micDelay: TimeInterval
    let muteTimeline: [MuteTransition]
    let recordingStart: TimeInterval  // ProcessInfo.systemUptime
}

@Observable
class DualSourceRecorder {
    private var audiotapProcess: Process?
    private var micRecorder: MicRecorder?
    private var muteDetector: MuteDetector?

    func start(appPID: pid_t?, noMic: Bool = false,
               micDeviceUID: String? = nil) async throws
    // 1. Start audiotap subprocess:
    //    [audiotap, appPID, 48000, 2, --mic mic_output.wav]
    //    Read float32 stereo from stdout → app_audio.wav
    // 2. If not noMic and audiotap doesn't handle mic:
    //    Start MicRecorder
    // 3. Start MuteDetector if Teams PID

    func stop() async throws -> RecordingResult
    // 1. Stop MuteDetector
    // 2. Stop MicRecorder
    // 3. Terminate audiotap (SIGTERM, wait 3s, SIGKILL)
    // 4. Parse audiotap stderr: MIC_DELAY=, ACTUAL_RATE=
    // 5. Mix tracks via AudioMixer
    // 6. Save individual tracks to ~/Library/.../recordings/
    // 7. Return RecordingResult
}
```

### Task 3.4: Tests

```swift
// New file: app/MeetingTranscriber/Tests/MicRecorderTests.swift
// - Verify WAV output format (48kHz, mono, Float32)
// - Test device listing

// New file: app/MeetingTranscriber/Tests/AudioMixerTests.swift
// - Test echo suppression with known signals
// - Test mute masking zeroes correct samples
// - Test resampling 48kHz → 16kHz
// - Test mic delay alignment

// New file: app/MeetingTranscriber/Tests/DualSourceRecorderTests.swift
// - Mock audiotap process
// - Verify RecordingResult fields
```

### Verification
- `cd app/MeetingTranscriber && swift test`
- Manual: Record mic audio, verify WAV output is 48kHz mono
- Compare mixed output with Python-generated reference

---

## Phase 4: Transcription (WhisperKit as Default)

**Duration:** 1 week
**Goal:** Make WhisperKit the primary transcription engine. Add dual-source support.

### Task 4.1: Extend WhisperKitEngine

Already exists at `WhisperKitEngine.swift`. Add dual-source support.

```swift
// Edit: app/MeetingTranscriber/Sources/WhisperKitEngine.swift

// Add:
struct TimestampedSegment {
    let start: TimeInterval  // seconds
    let end: TimeInterval    // seconds
    let text: String
    var speaker: String = ""
}

extension WhisperKitEngine {
    func transcribeSegments(audioPath: URL) async throws -> [TimestampedSegment]
    // Like transcribe() but returns structured segments
    // Enable wordTimestamps for segment-level timing

    func transcribeDualSource(
        appAudio: URL, micAudio: URL,
        micDelay: TimeInterval,
        micLabel: String = "Me"
    ) async throws -> String
    // 1. Transcribe app audio → app segments
    // 2. Transcribe mic audio → mic segments
    // 3. Shift mic timestamps by micDelay
    // 4. Label mic segments as micLabel
    // 5. Label app segments as "Remote"
    // 6. Merge by timestamp, format as "[MM:SS] Speaker: text"
}
```

### Task 4.2: Remove NativeTranscriptionManager Indirection

Currently `NativeTranscriptionManager` watches for `recording_done` status from Python,
then transcribes. After migration, the Swift WatchLoop calls WhisperKit directly.

- Inline `NativeTranscriptionManager` functionality into `WatchLoop.swift` (Phase 5)
- Delete `NativeTranscriptionManager.swift` after Phase 5

### Task 4.3: Tests

```swift
// New file: app/MeetingTranscriber/Tests/WhisperKitDualSourceTests.swift
// - Transcribe fixtures/two_speakers_de.wav
// - Test segment merging by timestamp
// - Test speaker labeling
// - Compare output format with Python version

// Extend: app/MeetingTranscriber/Tests/WhisperKitEngineTests.swift
// - Test transcribeSegments returns TimestampedSegment array
// - Test timestamp formatting [MM:SS] and [H:MM:SS]
```

### Verification
- `cd app/MeetingTranscriber && swift test`
- Transcribe `fixtures/two_speakers_de.wav`, compare with Python pywhispercpp output

---

## Phase 5: Protocol Generation (Native Swift)

**Duration:** 3 days
**Goal:** Call Claude CLI from Swift instead of Python.

### Task 5.1: ProtocolGenerator.swift

Port `protocol.py` to Swift.

```swift
// New file: app/MeetingTranscriber/Sources/ProtocolGenerator.swift

struct ProtocolGenerator {
    static let protocolPrompt = """
    ... (German template, copy from config.py PROTOCOL_PROMPT)
    """

    static func generate(
        transcript: String,
        title: String = "Meeting",
        diarized: Bool = false,
        claudeBin: String = "claude"
    ) async throws -> String
    // 1. Build prompt: protocolPrompt + diarization note + transcript
    // 2. Spawn Process:
    //    [claude, -p, -, --output-format, stream-json, --verbose, --model, sonnet]
    // 3. Write prompt to stdin, close stdin
    // 4. Read stdout line-by-line (stream-json):
    //    - Parse JSON: type "content_block_delta" → extract text_delta
    //    - Accumulate text chunks
    // 5. Return accumulated protocol markdown
    // 6. Timeout: 600 seconds

    static func saveTranscript(_ text: String, title: String, dir: URL) throws -> URL
    // Format: {yyyyMMdd_HHmm}_{slug}.txt

    static func saveProtocol(_ markdown: String, title: String, dir: URL) throws -> URL
    // Format: {yyyyMMdd_HHmm}_{slug}.md
}
```

### Task 5.2: Tests

```swift
// New file: app/MeetingTranscriber/Tests/ProtocolGeneratorTests.swift
// - Mock claude CLI process (echo back input)
// - Test stream-json parsing
// - Test file naming format
// - Test prompt construction with/without diarization
```

### Verification
- `cd app/MeetingTranscriber && swift test`
- Manual: Generate protocol from known transcript, compare with Python output

---

## Phase 6: Watch Loop (Native Swift Orchestration)

**Duration:** 4 days
**Goal:** Replace Python watcher.py with Swift WatchLoop. Remove PythonProcess dependency for main pipeline.

### Task 6.1: WatchLoop.swift

Port `watcher.py` orchestration to Swift.

```swift
// New file: app/MeetingTranscriber/Sources/WatchLoop.swift

@Observable
class WatchLoop {
    enum State { case idle, watching, recording, transcribing, generatingProtocol, done, error }

    private(set) var state: State = .idle
    private(set) var currentMeeting: DetectedMeeting?

    // Dependencies
    private let detector: MeetingDetector
    private let recorder: DualSourceRecorder
    private let whisperKit: WhisperKitEngine
    private let protocolGen = ProtocolGenerator.self
    private var diarizationProcess: DiarizationProcess?  // Phase 7

    // Settings
    let pollInterval: TimeInterval     // default 3.0
    let endGracePeriod: TimeInterval   // default 15.0
    let outputDir: URL
    let diarizeEnabled: Bool
    let micLabel: String               // default "Me"
    let noMic: Bool
    let claudeBin: String              // default "claude"

    private var watchTask: Task<Void, Never>?

    func start() async
    // 1. State = .watching
    // 2. Loop:
    //    a. detector.checkOnce()
    //    b. If meeting detected → handleMeeting()
    //    c. Sleep(pollInterval)

    func stop()
    // Cancel watchTask, stop recording if active

    private func handleMeeting(_ meeting: DetectedMeeting) async
    // 1. State = .recording
    // 2. Start DualSourceRecorder
    // 3. Read participants via ParticipantReader (if Teams)
    // 4. Wait for meeting end (poll detector.isMeetingActive with grace period)
    //    - Max duration: 14400 seconds (4 hours)
    // 5. Stop recorder → RecordingResult
    // 6. State = .transcribing
    // 7. Resample mix to 16kHz
    // 8. WhisperKit transcribe (single or dual source)
    // 9. If diarizeEnabled → call DiarizationProcess (Phase 7)
    // 10. State = .generatingProtocol
    // 11. ProtocolGenerator.generate(transcript, title)
    // 12. Save transcript + protocol
    // 13. State = .done
    // 14. Send notification
    // 15. State = .watching (back to monitoring)
}
```

### Task 6.2: Update MeetingTranscriberApp.swift

Replace PythonProcess with WatchLoop.

```swift
// Edit: app/MeetingTranscriber/Sources/MeetingTranscriberApp.swift

// Remove:
// - PythonProcess
// - WindowListWriter
// - StatusMonitor (state is now native)
// - NativeTranscriptionManager

// Add:
@State private var watchLoop: WatchLoop

// toggleWatching():
//   watchLoop.start() / watchLoop.stop()

// MenuBarView reads watchLoop.state directly instead of StatusMonitor
```

### Task 6.3: Update MenuBarView.swift

Replace StatusMonitor-based state with WatchLoop.state.

```swift
// Edit: app/MeetingTranscriber/Sources/MenuBarView.swift

// Replace: monitor.status.state
// With: watchLoop.state
// Map WatchLoop.State to UI strings/icons
```

### Task 6.4: Tests

```swift
// New file: app/MeetingTranscriber/Tests/WatchLoopTests.swift
// - State machine: idle → watching → recording → transcribing → done → watching
// - Grace period: meeting disappears, comes back within grace → don't stop
// - Max duration enforcement
// - Error handling: recorder fails → state = error → back to watching
```

### Verification
- `cd app/MeetingTranscriber && swift test`
- Manual: Start watching, join Teams meeting, verify full pipeline runs natively

---

## Phase 7: Diarization as Standalone Python

**Duration:** 3 days
**Goal:** Extract diarization into minimal standalone script. Swift calls it via subprocess.

### Task 7.1: Standalone diarize.py

```python
# New file: tools/diarize/diarize.py
# Standalone script — NO dependency on meeting_transcriber package

"""
Usage: python diarize.py <wav_path> [--speakers N] [--speakers-db PATH]
                         [--merge-threshold 0.92] [--expected-names "A,B,C"]
                         [--ipc-dir PATH]

Output: JSON to stdout
{
  "segments": [
    {"start": 0.0, "end": 5.2, "speaker": "SPEAKER_00"},
    ...
  ],
  "embeddings": {
    "SPEAKER_00": [0.1, 0.2, ...],  // 192-dim vector
    ...
  },
  "auto_names": {
    "SPEAKER_00": "John",  // matched from speakers.json
    ...
  },
  "speaking_times": {
    "SPEAKER_00": 125.3,
    ...
  }
}

If --ipc-dir is set:
  1. Write speaker_request.json
  2. Poll speaker_response.json (timeout 300s)
  3. Output final named segments
"""

# Port from src/meeting_transcriber/diarize.py:
# - diarize() function
# - load_speaker_db() / save_speaker_db()
# - match_speakers() / cosine_similarity()
# - extract_speaker_samples()
# - Speaker IPC (request/response JSON)
# - HF token resolution (env → .env)
```

### Task 7.2: requirements.txt

```
# New file: tools/diarize/requirements.txt
pyannote-audio>=3.1
torch>=2.0
sounddevice>=0.4
numpy>=1.24
scipy>=1.10
```

### Task 7.3: DiarizationProcess.swift

```swift
// New file: app/MeetingTranscriber/Sources/DiarizationProcess.swift

struct DiarizationResult {
    let segments: [(start: TimeInterval, end: TimeInterval, speaker: String)]
    let speakingTimes: [String: TimeInterval]
}

class DiarizationProcess {
    private let pythonPath: URL  // Resources/python-diarize/bin/python3
    private let scriptPath: URL  // Resources/python-diarize/diarize.py
    private let ipcDir: URL      // ~/.meeting-transcriber

    var isAvailable: Bool
    // Check if python-diarize/ exists in bundle

    func run(
        audioPath: URL,
        numSpeakers: Int? = nil,
        expectedNames: [String] = [],
        speakersDB: URL? = nil
    ) async throws -> DiarizationResult
    // 1. Build command:
    //    [pythonPath, scriptPath, audioPath,
    //     --speakers N, --speakers-db PATH,
    //     --expected-names "A,B,C",
    //     --ipc-dir ~/.meeting-transcriber]
    // 2. Set env: HF_TOKEN from Keychain
    // 3. Run Process, capture stdout
    // 4. Parse JSON output
    // 5. Return DiarizationResult

    func formatDiarizedTranscript(
        transcript: [TimestampedSegment],
        diarization: DiarizationResult
    ) -> String
    // Assign speaker labels to transcript segments by time overlap
    // Format: "[MM:SS] Speaker: text"
}
```

### Task 7.4: Update Build Script

```bash
# Edit: scripts/build_release.sh

# Replace Step 2 (full pip install) with:
# Step 2a: Create minimal diarization venv
DIARIZE_ENV="$RESOURCES/python-diarize"
"$PYTHON_BIN" -m venv "$DIARIZE_ENV"
"$DIARIZE_ENV/bin/pip" install -r "$PROJECT_ROOT/tools/diarize/requirements.txt" --quiet

# Step 2b: Copy standalone script
cp "$PROJECT_ROOT/tools/diarize/diarize.py" "$DIARIZE_ENV/"

# Step 2c: Cleanup (remove CUDA, tests, pip, etc.)
# Same cleanup as current Step 6 but much less to clean
```

### Task 7.5: Tests

```swift
// New file: app/MeetingTranscriber/Tests/DiarizationProcessTests.swift
// - Mock Python subprocess (echo test JSON)
// - Test JSON parsing
// - Test isAvailable when venv missing
// - Test speaker label assignment to transcript
```

```python
# Keep existing Python tests:
# tests/test_diarize.py — test diarize.py directly
# tests/test_e2e_diarize.py — E2E with real audio
# tests/test_speaker_ipc.py — IPC format tests
```

### Verification
- `cd app/MeetingTranscriber && swift test`
- `python tools/diarize/diarize.py fixtures/two_speakers_de.wav --speakers 2`
- `pytest tests/test_diarize.py tests/test_e2e_diarize.py -v`

---

## Phase 8: Cleanup + Build Script

**Duration:** 2 days
**Goal:** Remove unused Python code from app bundle. Simplify build and CI.

### Task 8.1: Remove Unused Swift Files

Delete files no longer needed:
- `PythonProcess.swift` → replaced by WatchLoop
- `StatusMonitor.swift` → state is native
- `WindowListWriter.swift` → detection is native
- `NativeTranscriptionManager.swift` → inlined into WatchLoop
- `TranscriberStatus.swift` → no longer parsing Python status

### Task 8.2: Simplify Build Script

```bash
# scripts/build_release.sh changes:

# Remove: Step 1 (download python-build-standalone) — only if diarize enabled
# Remove: Step 2 (pip install meeting-transcriber)
# Keep: Step 3 (build audiotap)
# Keep: Step 4 (build Swift app)
# Keep: Step 5 (assemble bundle)
# Add: Step 2 (optional): build diarization venv if --with-diarize flag
# Simplify: Step 6 (cleanup) — much less to clean
# Simplify: Step 7 (signing) — ~10 binaries instead of ~3000
```

### Task 8.3: Update CI Workflow

```yaml
# .github/workflows/release.yml

jobs:
  test:
    runs-on: macos-26
    steps:
      - uses: actions/checkout@v4
      - name: Swift tests
        run: cd app/MeetingTranscriber && swift test
      - name: Python diarization tests
        run: |
          python3 -m venv .venv
          .venv/bin/pip install -e ".[diarize,dev]"
          .venv/bin/pytest tests/test_diarize.py -v

  build:
    runs-on: macos-26
    needs: test
    steps:
      - uses: actions/checkout@v4
      - name: Build DMG
        run: ./scripts/build_release.sh --notarize --with-diarize
      # ... signing, notarization, upload
```

### Task 8.4: Update Package.swift Dependencies

Add WhisperKit as SPM dependency (if not already):

```swift
// app/MeetingTranscriber/Package.swift
dependencies: [
    .package(url: "https://github.com/argmaxinc/WhisperKit", from: "0.9.0"),
]
```

### Task 8.5: Keep Python Package for Windows/CLI

- `src/meeting_transcriber/` stays unchanged
- `pyproject.toml` keeps all dependencies
- `pip install meeting-transcriber` still works for Windows/CLI users
- Python tests for non-diarization modules become integration tests (optional)

### Verification
- Full build: `./scripts/build_release.sh --with-diarize`
- Bundle size: should be ~90 MB (vs ~300 MB)
- Code signing: `codesign -dvv .build/release/MeetingTranscriber.app`
- Notarization: `xcrun notarytool submit ... --wait`
- Manual E2E: detect → record → transcribe → diarize → protocol

---

## E2E Testing Strategy

### Swift E2E Test (replaces test_e2e_app_audio.py)

```swift
// New file: app/MeetingTranscriber/Tests/E2ETests.swift

// Test 1: Full pipeline without diarization
// 1. Create WatchLoop with mock MeetingDetector (returns instant DetectedMeeting)
// 2. Use fixture WAV instead of live recording
// 3. Transcribe with WhisperKit
// 4. Generate protocol (mock claude CLI)
// 5. Assert: transcript file exists, protocol file exists, content is non-empty

// Test 2: Full pipeline with diarization
// 1. Same as above
// 2. Add DiarizationProcess with mock Python subprocess
// 3. Assert: transcript has speaker labels

// Test 3: Meeting lifecycle
// 1. Inject mock window list → meeting detected after 2 polls
// 2. Recording starts
// 3. Remove mock window → grace period
// 4. Re-add mock window → recording continues
// 5. Remove again → grace expires → pipeline runs
```

### Python E2E Tests (kept for diarization)

```python
# tests/test_diarize.py — unit tests for standalone script
# tests/test_e2e_diarize.py — E2E with real audio fixture
# tests/test_speaker_ipc.py — IPC JSON format validation
```

### CI Pipeline

```yaml
jobs:
  swift-tests:
    runs-on: macos-26
    steps:
      - swift test  # ~250 tests including new E2E

  python-tests:
    runs-on: ubuntu-latest  # cheaper, diarization tests
    steps:
      - pip install -e ".[diarize,dev]"
      - pytest tests/test_diarize.py tests/test_speaker_ipc.py -v

  build:
    needs: [swift-tests, python-tests]
    runs-on: macos-26
    steps:
      - ./scripts/build_release.sh --notarize --with-diarize
```

---

## Risk Assessment

| Risk | Impact | Likelihood | Mitigation |
|------|--------|-----------|------------|
| WhisperKit accuracy differs | Medium | Low | Both use Whisper; test same audio |
| AVAudioEngine edge cases | Medium | Medium | audiotap handles app audio; mic is simpler |
| Diarization subprocess latency | Low | Low | Already async; user waits anyway |
| torch CPU-only still large | Low | Medium | ~40 MB acceptable; could strip further |
| CGWindowList needs Screen Recording | High | Known | Already handled; same permission as before |
| WhisperKit model download on first run | Medium | Known | Show progress in UI; cache model |

## Bundle Size Estimate

| Component | Current | After Migration |
|-----------|---------|-----------------|
| Python 3.14 runtime | 50 MB | 0 MB |
| site-packages (pywhispercpp, scipy, numpy, etc.) | 150 MB | 0 MB |
| torch + pyannote (full) | 100 MB | 0 MB |
| torch + pyannote (CPU-only, diarize venv) | — | ~50 MB |
| Swift app binary | 5 MB | 10 MB |
| WhisperKit model (large-v3-turbo) | — | ~40 MB |
| audiotap | 1 MB | 1 MB |
| **Total** | **~300 MB** | **~100 MB** |

## Windows Support

Python CLI (`transcribe` command) stays for Windows users:
- `pip install meeting-transcriber` — full Python package
- `audio/windows.py` — WASAPI loopback
- `transcription/windows.py` — faster-whisper
- All watch/diarize/protocol modules work cross-platform
- Python tests on `ubuntu-latest` in CI

**Two distribution channels:**
1. **macOS** — Swift app (DMG/Homebrew), optional diarize venv
2. **Windows/CLI** — `pip install meeting-transcriber` (pure Python)
