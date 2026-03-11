# Code Review Fixes Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Fix all critical and important issues from the 2026-03-07 code review (C1-C4, I1, I3, I4, I7, I8, P1, P2, P5).

**Architecture:** Replace blocking `Process.waitUntilExit()` with async `terminationHandler` continuations; add `@MainActor` for thread safety; fix data ownership issues. Python fixes are small targeted changes.

**Tech Stack:** Swift (SPM, XCTest), Python 3.14, macOS APIs (Process, CoreGraphics)

**Reference:** `docs/plans/2026-03-07-code-review-findings.md` for full analysis.

**Excluded:** I2 (duplicate resampling) — optimization, low risk. I5 (speaker count IPC) — feature addition, separate task. I6 (diarization timeout) — needs design decision on timeout value. P3 (embedding ordering) — needs pyannote research. P4 (poll retry) — low risk, unlikely.

---

### Task 1: C1+C2 — Fix pipe deadlock and thread blocking in DiarizationProcess

The most critical fix. `process.waitUntilExit()` at line 130 is called BEFORE reading stdout/stderr. If Python writes >64KB, it deadlocks. Additionally, `waitUntilExit()` blocks a cooperative thread pool thread.

**Files:**
- Modify: `app/MeetingTranscriber/Sources/DiarizationProcess.swift:129-139`
- Test: `app/MeetingTranscriber/Tests/DiarizationProcessTests.swift`

**Step 1: Write a test that verifies async process execution doesn't block**

Add to `DiarizationProcessTests.swift`:

```swift
func testRunWithLargeOutputDoesNotDeadlock() async throws {
    // Create a Python script that writes >64KB to stdout (pipe buffer size)
    let tmpDir = FileManager.default.temporaryDirectory
        .appendingPathComponent("diarize_test_\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tmpDir) }

    let scriptPath = tmpDir.appendingPathComponent("big_output.py")
    let script = """
        import json, sys
        # Generate >64KB of output (pipe buffer = 65536 on macOS)
        segments = [{"start": float(i), "end": float(i+1), "speaker": f"SPEAKER_{i:02d}"}
                    for i in range(200)]
        embeddings = {f"SPEAKER_{i:02d}": [0.1] * 512 for i in range(200)}
        result = {"segments": segments, "embeddings": embeddings,
                  "speaking_times": {}, "auto_names": {}}
        json.dump(result, sys.stdout)
        """
    try script.write(to: scriptPath, atomically: true, encoding: .utf8)

    let proc = DiarizationProcess(
        pythonPath: URL(fileURLWithPath: "/usr/bin/python3"),
        scriptPath: scriptPath
    )

    // This would deadlock before the fix (process blocks on write, Swift blocks on wait)
    let result = try await proc.run(
        audioPath: scriptPath, // dummy, script ignores it
        numSpeakers: nil,
        meetingTitle: "Test"
    )
    XCTAssertGreaterThan(result.segments.count, 100)
}
```

**Step 2: Run test to verify it fails (or hangs)**

```bash
cd app/MeetingTranscriber && swift test --filter DiarizationProcessTests/testRunWithLargeOutputDoesNotDeadlock
```

Expected: Hangs/deadlocks (timeout after 60s).

**Step 3: Fix DiarizationProcess.run() to use async termination**

Replace lines 129-139 in `DiarizationProcess.swift`:

```swift
// BEFORE (deadlock-prone):
// try process.run()
// process.waitUntilExit()

// AFTER:
try process.run()

// Read stdout/stderr asynchronously BEFORE waiting for exit
// This prevents deadlock when output exceeds 64KB pipe buffer
let stdoutData: Data
let stderrData: Data
async let stdoutRead = Task.detached {
    stdoutPipe.fileHandleForReading.readDataToEndOfFile()
}.value
async let stderrRead = Task.detached {
    stderrPipe.fileHandleForReading.readDataToEndOfFile()
}.value

// Wait for process to exit without blocking cooperative thread pool
await withCheckedContinuation { continuation in
    process.terminationHandler = { _ in
        continuation.resume()
    }
}

stdoutData = await stdoutRead
stderrData = await stderrRead

guard process.terminationStatus == 0 else {
    let stderr = String(data: stderrData, encoding: .utf8) ?? ""
    throw DiarizationError.processFailed(Int(process.terminationStatus), stderr)
}

return try parseOutput(stdoutData)
```

Remove the old `let stdoutData` and `let stderrData` lines (138, 133-134).

**Step 4: Run test to verify it passes**

```bash
cd app/MeetingTranscriber && swift test --filter DiarizationProcessTests
```

Expected: All pass, including the new large-output test.

**Step 5: Commit**

```bash
cd app/MeetingTranscriber
git add Sources/DiarizationProcess.swift Tests/DiarizationProcessTests.swift
git commit -m "fix(diarize): async process I/O to prevent pipe deadlock (C1+C2)

Use terminationHandler + withCheckedContinuation instead of
process.waitUntilExit(). Read stdout/stderr in detached Tasks
before awaiting termination to prevent deadlock when output
exceeds the 64KB pipe buffer.

Also fixes C2: no longer blocks cooperative thread pool threads."
```

---

### Task 2: C2 — Fix blocking thread pool in ProtocolGenerator

Same issue as C1 but for the Claude CLI subprocess.

**Files:**
- Modify: `app/MeetingTranscriber/Sources/ProtocolGenerator.swift:126-141`
- Test: `app/MeetingTranscriber/Tests/ProtocolGeneratorTests.swift`

**Step 1: Write a test for non-blocking protocol generation**

Add to `ProtocolGeneratorTests.swift`:

```swift
func testGenerateDoesNotBlockCooperativePool() async throws {
    // Use a simple echo-like command instead of real Claude CLI
    // The key test is that the async flow completes without blocking
    let text = try await ProtocolGenerator.generate(
        transcript: "Test",
        title: "Test",
        claudeBin: "echo"  // echo will just print args and exit
    )
    // echo outputs args, so we get something back or empty
    // The important thing: this completes without blocking
    XCTAssertNotNil(text)
}
```

Note: This test may already exist or may not work with `echo` since ProtocolGenerator expects stream-json. Skip writing a new test if the existing tests cover process execution. Focus on the code fix.

**Step 2: Fix ProtocolGenerator.generate() — replace waitUntilExit**

In `ProtocolGenerator.swift`, replace line 141 (`process.waitUntilExit()`):

```swift
// BEFORE:
// process.waitUntilExit()

// AFTER: Non-blocking wait
await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
    process.terminationHandler = { _ in
        continuation.resume()
    }
}
```

Also fix `readStreamJSON` — the `handle.availableData` loop (lines 171-174) blocks on I/O. Replace with a non-blocking approach:

```swift
private static func readStreamJSON(from pipe: Pipe, process: Process) async throws -> String {
    let handle = pipe.fileHandleForReading
    var parts: [String] = []
    let startTime = ProcessInfo.processInfo.systemUptime

    var buffer = Data()

    // Read chunks without blocking cooperative pool
    while true {
        if ProcessInfo.processInfo.systemUptime - startTime > timeoutSeconds {
            process.terminate()
            throw ProtocolError.timeout
        }

        let chunk: Data = await withCheckedContinuation { continuation in
            handle.readabilityHandler = { handle in
                handle.readabilityHandler = nil
                continuation.resume(returning: handle.availableData)
            }
        }
        if chunk.isEmpty { break } // EOF

        buffer.append(chunk)

        // Process complete lines
        while let newlineRange = buffer.range(of: Data([0x0A])) {
            let lineData = buffer[buffer.startIndex..<newlineRange.lowerBound]
            buffer.removeSubrange(buffer.startIndex...newlineRange.lowerBound)

            guard let line = String(data: lineData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
                !line.isEmpty else { continue }

            if let text = parseStreamJSONLine(line) {
                parts.append(text)
            }
        }
    }

    return parts.joined()
}
```

**Step 3: Run all tests**

```bash
cd app/MeetingTranscriber && swift test --filter ProtocolGeneratorTests
```

Expected: All pass.

**Step 4: Commit**

```bash
cd app/MeetingTranscriber
git add Sources/ProtocolGenerator.swift Tests/ProtocolGeneratorTests.swift
git commit -m "fix(protocol): async process I/O to prevent thread pool blocking (C2)

Replace process.waitUntilExit() with terminationHandler continuation.
Replace blocking availableData loop with readabilityHandler for
non-blocking I/O. Prevents starving Swift's cooperative thread pool
during long-running Claude CLI invocations."
```

---

### Task 3: C3 — Fix data race on IPCPoller.seenFiles

`seenFiles` is accessed from a background `Task` and mutated from the main thread. Add `@MainActor` to the entire class since polling is lightweight.

**Files:**
- Modify: `app/MeetingTranscriber/Sources/IPCPoller.swift`
- Test: `app/MeetingTranscriber/Tests/IPCPollerTests.swift`

**Step 1: Add `@MainActor` to IPCPoller**

In `IPCPoller.swift`:

```swift
@MainActor
class IPCPoller {
    // ... everything stays the same, except:

    func start() {
        stop()
        seenFiles.removeAll()
        logger.info("Started, watching: \(self.ipcDir.path)")
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.poll()
                try? await Task.sleep(for: .seconds(self?.pollInterval ?? 1.0))
            }
        }
    }

    // poll() and checkFile() already run on MainActor via self
    // No other changes needed
}
```

**Step 2: Update tests to use `@MainActor`**

In `IPCPollerTests.swift`, add `@MainActor` to the test class or annotate each test method:

```swift
@MainActor
final class IPCPollerTests: XCTestCase {
    // ... tests stay the same
}
```

**Step 3: Update MeetingTranscriberApp.swift callbacks**

The `onSpeakerCountRequest` and `onSpeakerRequest` callbacks are already dispatched to `DispatchQueue.main.async`, which is compatible with `@MainActor`. No changes needed in `MeetingTranscriberApp.swift`.

**Step 4: Run tests**

```bash
cd app/MeetingTranscriber && swift test --filter IPCPollerTests
```

Expected: All pass.

**Step 5: Commit**

```bash
cd app/MeetingTranscriber
git add Sources/IPCPoller.swift Tests/IPCPollerTests.swift
git commit -m "fix(app): add @MainActor to IPCPoller to prevent data race (C3)

seenFiles was accessed from a background Task and mutated from the
main thread without synchronization. @MainActor ensures all access
is serialized on the main thread. Polling is lightweight (1s interval)
so main thread overhead is negligible."
```

---

### Task 4: C4 — Fix recordingStart captured at wrong time

`DualSourceRecorder.stop()` captures `ProcessInfo.processInfo.systemUptime` when stop is called, not when recording started. This breaks mute mask correlation.

**Files:**
- Modify: `app/MeetingTranscriber/Sources/DualSourceRecorder.swift:31,78,150`
- Test: `app/MeetingTranscriber/Tests/DualSourceRecorderTests.swift`

**Step 1: Write a test that verifies recordingStart is captured at start time**

Add to `DualSourceRecorderTests.swift`:

```swift
func testRecordingStartCapturedAtStartTime() throws {
    // We can't easily test with real audio, but we can verify the property
    let recorder = DualSourceRecorder()
    let beforeStart = ProcessInfo.processInfo.systemUptime

    // Note: start() requires a real audiotap binary, so we test the property directly
    // If audiotap is available, do a real test; otherwise verify the property exists
    XCTAssertEqual(recorder.recordingStartTime, 0, "Should be 0 before recording starts")
}
```

This is hard to test without mocking audiotap. Better approach: just verify the fix is correct by reading the code. Skip test writing for this task.

**Step 2: Add `recordingStartTime` property, capture in start()**

In `DualSourceRecorder.swift`, add instance variable after line 31:

```swift
private(set) var recordingStartTime: TimeInterval = 0
```

In `start()`, after `isRecording = true` (line 115):

```swift
recordingStartTime = ProcessInfo.processInfo.systemUptime
```

In `stop()`, replace line 150:

```swift
// BEFORE:
// let recordingStart = ProcessInfo.processInfo.systemUptime

// AFTER:
let recordingStart = recordingStartTime
```

**Step 3: Run all tests**

```bash
cd app/MeetingTranscriber && swift test --filter DualSourceRecorderTests
```

Expected: All pass.

**Step 4: Commit**

```bash
cd app/MeetingTranscriber
git add Sources/DualSourceRecorder.swift
git commit -m "fix(audio): capture recordingStart at start() not stop() (C4)

systemUptime was captured in stop() instead of start(), causing
mute mask timestamps to be applied at wrong audio positions.
Now stored as instance variable at recording start time."
```

---

### Task 5: I1 — Fix WatchLoop @Observable data race

WatchLoop is `@Observable` with properties read by SwiftUI on main thread but mutated from background Tasks.

**Files:**
- Modify: `app/MeetingTranscriber/Sources/WatchLoop.swift`
- Test: `app/MeetingTranscriber/Tests/WatchLoopTests.swift`

**Step 1: Add `@MainActor` to WatchLoop**

In `WatchLoop.swift`, change line 10:

```swift
@MainActor
@Observable
class WatchLoop {
```

The `watchLoop()` and `handleMeeting()` methods already run inside a Task that captures `self`, which will now be dispatched to the MainActor. The heavy work (transcription, diarization) happens inside the injected providers (which are NOT MainActor-isolated), so they still run on background threads. Only state mutations are funneled through MainActor.

**Step 2: Mark `handleMeeting` and `watchLoop` as nonisolated where needed**

The provider calls (`whisperKit.transcribe()`, `diarizationFactory().run()`, `protocolGenerator.generate()`) are `async` and will hop off the MainActor automatically. No explicit `nonisolated` needed.

However, `waitForMeetingEnd` does polling in a tight loop. Since it only reads `detector.isMeetingActive()` and doesn't mutate WatchLoop state (just local vars), it's fine on MainActor.

**Step 3: Update `MeetingTranscriberApp.swift` if needed**

`WatchLoop` is created inside `await MainActor.run { }` (line 178), so it's already created on MainActor. The `onStateChange` closure captures `[notifications, ipcPoller]` which are already main-thread compatible. No changes needed.

**Step 4: Run tests**

```bash
cd app/MeetingTranscriber && swift test --filter WatchLoopTests
```

Expected: All pass. If tests create WatchLoop off the main thread, wrap in `@MainActor` or `await MainActor.run`.

**Step 5: Run ALL tests to catch cascading issues**

```bash
cd app/MeetingTranscriber && swift test
```

Expected: All pass.

**Step 6: Commit**

```bash
cd app/MeetingTranscriber
git add Sources/WatchLoop.swift Tests/WatchLoopTests.swift Tests/WatchLoopE2ETests.swift
git commit -m "fix(watch): add @MainActor to WatchLoop for thread safety (I1)

WatchLoop is @Observable and read by SwiftUI on the main thread,
but was mutated from background Tasks. @MainActor ensures all state
mutations are serialized. Async provider calls (transcription,
diarization) still run on background threads automatically."
```

---

### Task 6: I3 — Fix WhisperKitEngine double loading

`loadModel()` can be called concurrently from app init and from `ensureModel()`. Deduplicate with a stored Task reference.

**Files:**
- Modify: `app/MeetingTranscriber/Sources/WhisperKitEngine.swift:42-71`
- Test: `app/MeetingTranscriber/Tests/WhisperKitEngineTests.swift`

**Step 1: Add loading Task deduplication**

In `WhisperKitEngine.swift`, add a private property:

```swift
private var loadingTask: Task<Void, Never>?
```

Replace `loadModel()`:

```swift
func loadModel() async {
    // Deduplicate concurrent loads
    if let existing = loadingTask {
        await existing.value
        return
    }

    let task = Task { @MainActor in
        modelState = .downloading
        downloadProgress = 0
        do {
            let modelFolder = try await WhisperKit.download(
                variant: modelVariant,
                progressCallback: { progress in
                    Task { @MainActor in
                        self.downloadProgress = progress.fractionCompleted
                    }
                }
            )
            modelState = .loading
            downloadProgress = 1.0
            pipe = try await WhisperKit(
                WhisperKitConfig(
                    model: modelVariant,
                    modelFolder: modelFolder.path()
                )
            )
            modelState = .loaded
        } catch {
            NSLog("WhisperKit model load failed: \(error)")
            modelState = .unloaded
            downloadProgress = 0
        }
        loadingTask = nil
    }
    loadingTask = task
    await task.value
}
```

**Step 2: Run tests**

```bash
cd app/MeetingTranscriber && swift test --filter WhisperKitEngineTests
```

Expected: All pass.

**Step 3: Commit**

```bash
cd app/MeetingTranscriber
git add Sources/WhisperKitEngine.swift
git commit -m "fix(app): deduplicate concurrent WhisperKit model loading (I3)

Store loading Task reference to prevent concurrent loadModel() calls
from app init and ensureModel(). Second caller awaits the existing
task instead of starting a duplicate download."
```

---

### Task 7: I4 — Share WhisperKitEngine instance with SettingsView

SettingsView creates its own WhisperKitEngine, disconnected from the pipeline.

**Files:**
- Modify: `app/MeetingTranscriber/Sources/SettingsView.swift:35`
- Modify: `app/MeetingTranscriber/Sources/MeetingTranscriberApp.swift:111-113`
- Test: `app/MeetingTranscriber/Tests/SettingsViewTests.swift`

**Step 1: Change SettingsView to accept WhisperKitEngine as parameter**

In `SettingsView.swift`, replace line 35:

```swift
// BEFORE:
// @State private var whisperKitEngine = WhisperKitEngine()

// AFTER:
var whisperKitEngine: WhisperKitEngine
```

**Step 2: Pass engine from app**

In `MeetingTranscriberApp.swift`, change the Settings Window (line 111-113):

```swift
Window("Settings", id: "settings") {
    SettingsView(settings: settings, whisperKitEngine: whisperKit)
}
```

**Step 3: Update SettingsView tests**

In `SettingsViewTests.swift`, update any test that creates a `SettingsView` to pass a `WhisperKitEngine()` instance:

```swift
// Where tests create SettingsView, add the engine parameter:
SettingsView(settings: AppSettings(), whisperKitEngine: WhisperKitEngine())
```

**Step 4: Run tests**

```bash
cd app/MeetingTranscriber && swift test --filter SettingsViewTests
```

Expected: All pass.

**Step 5: Commit**

```bash
cd app/MeetingTranscriber
git add Sources/SettingsView.swift Sources/MeetingTranscriberApp.swift Tests/SettingsViewTests.swift
git commit -m "fix(app): share WhisperKitEngine between app and SettingsView (I4)

SettingsView had its own WhisperKitEngine instance, disconnected
from the pipeline. Now receives the app's shared instance so model
status is accurate and loading in Settings pre-loads for the pipeline."
```

---

### Task 8: I7 — Fix MeetingDetector over-counting in single poll

Multiple windows matching the same pattern increment the counter multiple times per poll, potentially satisfying `confirmationCount` in one cycle.

**Files:**
- Modify: `app/MeetingTranscriber/Sources/MeetingDetector.swift:52-77`
- Test: `app/MeetingTranscriber/Tests/MeetingDetectorTests.swift`

**Step 1: Write a test for multi-window over-counting**

Add to `MeetingDetectorTests.swift`:

```swift
func testMultipleMatchingWindowsCountOncePerPoll() {
    let detector = MeetingDetector(patterns: [.teams], confirmationCount: 2)
    // Two windows both match Teams meeting pattern
    detector.windowListProvider = {
        [
            makeWindow(owner: "Microsoft Teams", name: "Sprint Review | Microsoft Teams", pid: 1000),
            makeWindow(owner: "Microsoft Teams", name: "Sprint Review | Microsoft Teams", pid: 1001),
        ]
    }

    // First poll: should NOT detect (needs 2 consecutive polls, not 2 windows)
    XCTAssertNil(detector.checkOnce())
    // Second poll: NOW should detect
    XCTAssertNotNil(detector.checkOnce())
}
```

**Step 2: Run test to verify it fails**

```bash
cd app/MeetingTranscriber && swift test --filter MeetingDetectorTests/testMultipleMatchingWindowsCountOncePerPoll
```

Expected: FAIL — first `checkOnce()` returns non-nil (counter hits 2 from two windows in one poll).

**Step 3: Fix checkOnce() to increment once per pattern per poll**

In `MeetingDetector.swift`, modify `checkOnce()`:

```swift
func checkOnce() -> DetectedMeeting? {
    let windows = windowListProvider()
    var hitsThisRound: Set<String> = []
    var firstMatch: [String: (title: String, window: [String: Any])] = [:]

    for window in windows {
        for pattern in patterns {
            // Skip apps in cooldown
            if let until = cooldownUntil[pattern.appName], Date() < until {
                continue
            }
            // Only count each pattern once per poll
            guard !hitsThisRound.contains(pattern.appName) else { continue }

            if let title = matchWindow(window, pattern: pattern) {
                hitsThisRound.insert(pattern.appName)
                firstMatch[pattern.appName] = (title, window)
                consecutiveHits[pattern.appName, default: 0] += 1
            }
        }
    }

    // Check if any pattern reached confirmation threshold
    for (appName, hits) in consecutiveHits {
        if hits >= confirmationCount, let match = firstMatch[appName] {
            let pattern = patterns.first { $0.appName == appName }!
            let pid = match.window["kCGWindowOwnerPID"] as? Int32 ?? 0
            return DetectedMeeting(
                pattern: pattern,
                windowTitle: match.title,
                ownerName: match.window["kCGWindowOwnerName"] as? String ?? "",
                windowPID: pid
            )
        }
    }

    // Reset counters for apps that had no hit this round
    for appName in consecutiveHits.keys {
        if !hitsThisRound.contains(appName) {
            consecutiveHits[appName] = 0
        }
    }

    return nil
}
```

**Step 4: Run tests**

```bash
cd app/MeetingTranscriber && swift test --filter MeetingDetectorTests
```

Expected: All pass (including the new test).

**Step 5: Commit**

```bash
cd app/MeetingTranscriber
git add Sources/MeetingDetector.swift Tests/MeetingDetectorTests.swift
git commit -m "fix(watch): count each pattern once per poll cycle (I7)

Multiple windows matching the same app pattern (e.g. Teams has
multiple meeting-titled windows) incremented the counter multiple
times per poll, potentially satisfying confirmationCount in a
single cycle. Now tracks which patterns matched per round and
increments at most once per pattern."
```

---

### Task 9: I8 — Fix AppSettings() created separately in init()

App init creates a separate `AppSettings()` instead of using `self.settings`.

**Files:**
- Modify: `app/MeetingTranscriber/Sources/MeetingTranscriberApp.swift:26-41`

**Step 1: Move model loading to a .task modifier**

In `MeetingTranscriberApp.swift`, remove the model loading from `init()` and add a `.task` modifier to the MenuBarExtra label:

Remove from `init()` (lines 28-33):
```swift
// Remove:
// let engine = whisperKit
// Task {
//     engine.modelVariant = AppSettings().whisperKitModel
//     await engine.loadModel()
// }
```

Add `.task` modifier to the MenuBarExtra label view (after the existing `.onReceive` modifiers, around line 80):

```swift
.task {
    whisperKit.modelVariant = settings.whisperKitModel
    await whisperKit.loadModel()
}
```

The `.task` modifier runs when the view appears and has access to `settings` and `whisperKit`.

Simplify `init()` to only handle auto-watch:

```swift
init() {
    notifications.setUp()
    if CommandLine.arguments.contains("--auto-watch")
        || UserDefaults.standard.bool(forKey: "autoWatch") {
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            NotificationCenter.default.post(name: .autoWatchStart, object: nil)
        }
    }
}
```

**Step 2: Run all tests**

```bash
cd app/MeetingTranscriber && swift test
```

Expected: All pass.

**Step 3: Commit**

```bash
cd app/MeetingTranscriber
git add Sources/MeetingTranscriberApp.swift
git commit -m "fix(app): use shared settings for WhisperKit model loading (I8)

Moved model loading from init() to .task modifier so it can
access self.settings instead of creating a separate AppSettings()
instance. Ensures single source of truth for model variant."
```

---

### Task 10: P1 — Add expected_names to SpeakerRequest

Python writes `expected_names` in `speaker_request.json`, but Swift's `SpeakerRequest` ignores it.

**Files:**
- Modify: `app/MeetingTranscriber/Sources/SpeakerRequest.swift:4-16`
- Test: `app/MeetingTranscriber/Tests/SpeakerIPCTests.swift`

**Step 1: Write a test for expected_names decoding**

Add to `SpeakerIPCTests.swift`:

```swift
func testSpeakerRequestDecodesExpectedNames() throws {
    let json = """
        {
          "version": 1,
          "timestamp": "2026-03-07T12:00:00",
          "meeting_title": "Standup",
          "audio_samples_dir": "/tmp/samples",
          "speakers": [],
          "expected_names": ["Alice", "Bob"]
        }
        """
    let request = try JSONDecoder().decode(SpeakerRequest.self, from: Data(json.utf8))
    XCTAssertEqual(request.expectedNames, ["Alice", "Bob"])
}

func testSpeakerRequestDecodesWithoutExpectedNames() throws {
    let json = """
        {
          "version": 1,
          "timestamp": "2026-03-07T12:00:00",
          "meeting_title": "Standup",
          "audio_samples_dir": "/tmp/samples",
          "speakers": []
        }
        """
    let request = try JSONDecoder().decode(SpeakerRequest.self, from: Data(json.utf8))
    XCTAssertNil(request.expectedNames)
}
```

**Step 2: Run tests to verify they fail**

```bash
cd app/MeetingTranscriber && swift test --filter SpeakerIPCTests
```

Expected: Compilation error — `SpeakerRequest` has no member `expectedNames`.

**Step 3: Add the field**

In `SpeakerRequest.swift`, add to the struct:

```swift
struct SpeakerRequest: Codable {
    let version: Int
    let timestamp: String
    let meetingTitle: String
    let audioSamplesDir: String
    let speakers: [SpeakerInfo]
    let expectedNames: [String]?

    enum CodingKeys: String, CodingKey {
        case version, timestamp, speakers
        case meetingTitle = "meeting_title"
        case audioSamplesDir = "audio_samples_dir"
        case expectedNames = "expected_names"
    }
}
```

**Step 4: Run tests**

```bash
cd app/MeetingTranscriber && swift test --filter SpeakerIPCTests
```

Expected: All pass.

**Step 5: Commit**

```bash
cd app/MeetingTranscriber
git add Sources/SpeakerRequest.swift Tests/SpeakerIPCTests.swift
git commit -m "feat(app): decode expected_names from speaker request IPC (P1)

Python writes expected_names in speaker_request.json but Swift's
SpeakerRequest didn't declare the field. Added as optional [String]?
so SpeakerNamingView can use expected names as suggestions."
```

---

### Task 11: P2 — Guard dotenv import in src/meeting_transcriber/diarize.py

The `from dotenv import load_dotenv` at line 503 has no try/except.

**Files:**
- Modify: `src/meeting_transcriber/diarize.py:502-505`

**Step 1: Fix the import**

Replace lines 502-505:

```python
# BEFORE:
# from dotenv import load_dotenv
# load_dotenv()

# AFTER:
try:
    from dotenv import load_dotenv
    load_dotenv()
except ImportError:
    pass
```

**Step 2: Run Python tests**

```bash
pytest tests/test_diarize.py -v
```

Expected: All pass.

**Step 3: Commit**

```bash
git add src/meeting_transcriber/diarize.py
git commit -m "fix(diarize): guard dotenv import with try/except (P2)

The standalone diarize.py correctly wrapped the import, but
src/meeting_transcriber/diarize.py had a hard import that would
raise ImportError if python-dotenv is not installed."
```

---

### Task 12: P5 — Fix save_speaker_db truncate-before-lock

`open(path, "w")` truncates before `flock()` acquires the lock. Use atomic write instead.

**Files:**
- Modify: `tools/diarize/diarize.py:81-89`

**Step 1: Fix with atomic write**

Replace `save_speaker_db`:

```python
def save_speaker_db(db: dict[str, list[float]], db_path: Path) -> None:
    """Save speaker embeddings to JSON (atomic write)."""
    db_path.parent.mkdir(parents=True, exist_ok=True)
    tmp_path = db_path.with_suffix(".tmp")
    with open(tmp_path, "w", encoding="utf-8") as f:
        json.dump(db, f, indent=2, ensure_ascii=False)
    os.replace(tmp_path, db_path)
```

This is safe because `os.replace()` is atomic on the same filesystem.

**Step 2: Run Python tests**

```bash
pytest tests/test_diarize.py -v
```

Expected: All pass.

**Step 3: Commit**

```bash
git add tools/diarize/diarize.py
git commit -m "fix(diarize): atomic write for speaker DB to prevent corruption (P5)

open(path, 'w') truncated the file before flock() acquired the lock.
Replace with write-to-temp + os.replace() for atomic file updates."
```

---

## Verification

After all tasks:

```bash
# Swift tests
cd app/MeetingTranscriber && swift test

# Python tests
cd /Users/roman/git/Transcriber && pytest tests/ -v -m "not slow"

# Lint
ruff check src/ tests/ && ruff format src/ tests/
```

All should pass.

## Execution Order & Dependencies

Tasks are independent and can be parallelized in groups:

- **Batch 1** (Swift process fixes): Tasks 1, 2 (C1+C2 are related, similar pattern)
- **Batch 2** (Swift thread safety): Tasks 3, 4, 5 (C3, C4, I1 — independent)
- **Batch 3** (Swift refactors): Tasks 6, 7, 8, 9 (I3, I4, I7, I8 — independent)
- **Batch 4** (IPC + Python): Tasks 10, 11, 12 (P1, P2, P5 — independent)
