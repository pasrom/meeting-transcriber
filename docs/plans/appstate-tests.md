# AppState Test Expansion Plan

## Overview

`AppStateTests.swift` currently covers only the nil/default state of four properties (6 tests). This plan expands coverage to all public methods and derived properties — 39 new tests across two files.

**All new tests go in `AppStateTests.swift`. All new mock/helper types go in `TestHelpers.swift`. No new files are created.**

---

## 1. Test Infrastructure to Add to TestHelpers.swift

### 1.1 makeSilentDetector()

```swift
/// Returns a PowerAssertionDetector that never detects a meeting.
func makeSilentDetector() -> PowerAssertionDetector {
    let d = PowerAssertionDetector()
    d.assertionProvider = { [:] }
    return d
}
```

### 1.2 makeTestWatchLoop()

Assigns `WatchLoop` directly into `state.watchLoop` to exercise derived properties without calling `toggleWatching()` (which calls `Permissions.ensureMicrophoneAccess()`).

```swift
@MainActor
func makeTestWatchLoop(
    pipelineQueue: PipelineQueue? = nil,
) -> (WatchLoop, MockRecorder) {
    let recorder = MockRecorder()
    let loop = WatchLoop(
        detector: makeSilentDetector(),
        recorderFactory: { recorder },
        pipelineQueue: pipelineQueue,
        pollInterval: 0.05,
        endGracePeriod: 0.1,
    )
    return (loop, recorder)
}
```

### 1.3 makeState() helper in AppStateTests

Add a private factory to `AppStateTests` for consistent setup:

```swift
private func makeState() -> (AppState, RecordingNotifier) {
    let notifier = RecordingNotifier()
    let state = AppState(notifier: notifier)
    return (state, notifier)
}
```

`RecordingNotifier` is already defined in `AppStateTests.swift` — move it to `TestHelpers.swift` so it can be reused across test files.

### 1.4 makeIsolatedState() — for pipeline callback tests

Pipeline tests write snapshot files to disk. Use a temp logDir to keep tests filesystem-isolated:

```swift
private func makeIsolatedState(logDir: URL) -> (AppState, RecordingNotifier) {
    let notifier = RecordingNotifier()
    let state = AppState(notifier: notifier)
    state.pipelineQueue = PipelineQueue(logDir: logDir)
    return (state, notifier)
}
```

Follow the same `setUp`/`tearDown` temp-directory pattern as `PipelineQueueTests.swift`.

---

## 2. Derived Properties with Active WatchLoop

These tests assign a `WatchLoop` directly to `state.watchLoop` — no `toggleWatching()` needed.

### 2.1 isWatching (3 tests)

| Test | Setup | Expected |
|---|---|---|
| `testIsWatchingTrueWhenLoopActiveNotManual` | `loop.start()` | `true` |
| `testIsWatchingFalseWhenLoopNotActive` | no start | `false` |
| `testIsWatchingFalseWhenManualRecording` | `try loop.startManualRecording(pid:...)` | `false` |

### 2.2 currentStateLabel (3 tests)

| Test | Setup | Expected |
|---|---|---|
| `testCurrentStateLabelWatchingWhenLoopActive` | `loop.start()` | `"Watching for Meetings..."` |
| `testCurrentStateLabelRecordingWhenManualRecording` | `try loop.startManualRecording(...)` | `"Recording"` |
| `testCurrentStateLabelIdleWhenLoopStopped` | `loop.start()` then `loop.stop()` | `"Idle"` |

### 2.3 currentStatus (6 tests)

| Test | Setup | Expected |
|---|---|---|
| `testCurrentStatusNilWhenLoopInactive` | no start | `nil` |
| `testCurrentStatusNotNilWhenLoopActive` | `loop.start()` | `!= nil` |
| `testCurrentStatusStateMatchesLoopTranscriberState` | `loop.start()` | `.state == .watching` |
| `testCurrentStatusDetailMatchesLoopDetail` | `loop.start()` | `.detail == "Polling for meetings..."` |
| `testCurrentStatusMeetingNilWhenNoActiveMeeting` | `loop.start()` | `.meeting == nil` |
| `testCurrentStatusMeetingFromManualRecordingInfo` | `try loop.startManualRecording(pid: 42, appName: "Chrome", title: "Standup")` | `.meeting?.app == "Chrome"`, `.meeting?.title == "Standup"`, `.meeting?.pid == 42` |

Example for the manual recording status test:
```swift
func testCurrentStatusMeetingFromManualRecordingInfo() throws {
    let (state, _) = makeState()
    let (loop, _) = makeTestWatchLoop()
    state.watchLoop = loop
    try loop.startManualRecording(pid: 42, appName: "Chrome", title: "Standup")
    defer { loop.stop() }
    let status = try XCTUnwrap(state.currentStatus)
    XCTAssertEqual(status.meeting?.app, "Chrome")
    XCTAssertEqual(status.meeting?.title, "Standup")
    XCTAssertEqual(status.meeting?.pid, 42)
}
```

---

## 3. toggleWatching()

### 3.1 Permissions problem

`toggleWatching()` calls `Permissions.ensureMicrophoneAccess()` and hard-codes `PowerAssertionDetector()`. There is no detector injection point. **Strategy:**

- **Stop path:** assign a `WatchLoop` directly, call `toggleWatching()` — no permissions needed.
- **Start path:** call `toggleWatching()`, drain main actor with `await Task.yield()`, observe side effects.

### 3.2 Stop path (2 tests, synchronous)

| Test | Setup | Expected |
|---|---|---|
| `testToggleWatchingStopsActiveLoop` | assign active loop, call `toggleWatching()` | `state.watchLoop == nil` |
| `testToggleWatchingWhileManualRecordingIsNoOp` | assign manual-recording loop, call `toggleWatching()` | `state.watchLoop != nil` (unchanged) |

```swift
func testToggleWatchingStopsActiveLoop() {
    let (state, _) = makeState()
    let (loop, _) = makeTestWatchLoop()
    loop.start()
    state.watchLoop = loop
    XCTAssertTrue(state.isWatching)

    state.toggleWatching()

    XCTAssertNil(state.watchLoop)
}
```

### 3.3 Start path (2 tests, async)

In CI, `Permissions.ensureMicrophoneAccess()` returns `false` immediately (no app bundle). `toggleWatching()` ignores the return value, so `WatchLoop` is created regardless.

| Test | Expected |
|---|---|
| `testToggleWatchingCreatesWatchLoop` | `state.watchLoop != nil` after yield |
| `testToggleWatchingMakesLoopActive` | `state.watchLoop?.isActive == true` after yield |

```swift
func testToggleWatchingCreatesWatchLoop() async {
    let (state, _) = makeState()
    addTeardownBlock { state.watchLoop?.stop() }

    state.toggleWatching()
    await Task.yield()

    XCTAssertNotNil(state.watchLoop)
}
```

If a single `Task.yield()` proves insufficient on CI, use a bounded retry with `ContinuousClock` (max 500ms) — but only escalate if the single-yield test is actually flaky.

---

## 4. startManualRecording() (3 tests, async)

`startManualRecording()` also spawns `Task { @MainActor }`. `DualSourceRecorder.start()` requires `CATapDescription` and real audio hardware — it will throw in CI. The catch block fires `notifier.notify(title: "Error", ...)` and sets `watchLoop = nil`. Test both paths defensively.

| Test | Expected |
|---|---|
| `testStartManualRecordingCreatesOrCleansUpWatchLoop` | either `watchLoop != nil` (success) or `watchLoop == nil` + error notification (failure) |
| `testStartManualRecordingSendsNotification` | notifier called with either `"Manual Recording"` or `"Error"` |
| `testStartManualRecordingStopsExistingAutoWatchLoop` | old active loop is stopped |

```swift
func testStartManualRecordingSendsNotification() async {
    let (state, notifier) = makeState()
    state.startManualRecording(pid: 1234, appName: "Chrome", title: "Standup")
    await Task.yield()
    // Either success or error — both fire a notification
    XCTAssertTrue(
        notifier.calls.contains { $0.title == "Manual Recording" || $0.title == "Error" },
        "Expected at least one notification, got: \(notifier.calls)",
    )
}
```

---

## 5. stopManualRecording() (2 tests, synchronous)

| Test | Setup | Expected |
|---|---|---|
| `testStopManualRecordingClearsWatchLoop` | assign manual-recording loop | `state.watchLoop == nil` |
| `testStopManualRecordingWhenNoLoopIsNoOp` | no watchLoop | no crash, `state.watchLoop == nil` |

```swift
func testStopManualRecordingClearsWatchLoop() throws {
    let (state, _) = makeState()
    let (loop, _) = makeTestWatchLoop()
    state.watchLoop = loop
    try loop.startManualRecording(pid: 42, appName: "Chrome", title: "Meeting")

    state.stopManualRecording()

    XCTAssertNil(state.watchLoop)
}
```

---

## 6. enqueueFiles() (6 tests, synchronous)

Fully synchronous, no permissions, no audio hardware — the most reliable tests in this plan.

| Test | Input | Expected |
|---|---|---|
| `testEnqueueFilesSingleURL` | one URL | `jobs.count == 1` |
| `testEnqueueFilesMultipleURLs` | three URLs | `jobs.count == 3` |
| `testEnqueueFilesTitleFromLastPathComponent` | `/tmp/sprint-review.wav` | `jobs[0].meetingTitle == "sprint-review"` |
| `testEnqueueFilesAppNameIsFile` | any URL | `jobs[0].appName == "File"` |
| `testEnqueueFilesEmptyArrayIsNoOp` | `[]` | `jobs.isEmpty` |
| `testEnqueueFilesCreatesJobsWithNilPaths` | one URL | `jobs[0].appPath == nil`, `jobs[0].micPath == nil` |

```swift
func testEnqueueFilesSingleURL() {
    let (state, _) = makeState()
    let url = URL(fileURLWithPath: "/tmp/sprint-review.wav")

    state.enqueueFiles([url])

    XCTAssertEqual(state.pipelineQueue.jobs.count, 1)
    XCTAssertEqual(state.pipelineQueue.jobs[0].meetingTitle, "sprint-review")
    XCTAssertEqual(state.pipelineQueue.jobs[0].appName, "File")
}
```

---

## 7. ensurePipelineQueue() (2 tests, synchronous)

The bare `PipelineQueue()` from `AppState.init` has `whisperKit == nil`. The first call to `ensurePipelineQueue()` always replaces it.

| Test | Expected |
|---|---|
| `testEnsurePipelineQueueReplacesBareQueue` | `pipelineQueue.whisperKit != nil` |
| `testEnsurePipelineQueueIdempotent` | second call returns same queue identity |

```swift
func testEnsurePipelineQueueReplacesBareQueue() {
    let (state, _) = makeState()
    XCTAssertNil(state.pipelineQueue.whisperKit)
    state.ensurePipelineQueue()
    XCTAssertNotNil(state.pipelineQueue.whisperKit)
}

func testEnsurePipelineQueueIdempotent() {
    let (state, _) = makeState()
    state.ensurePipelineQueue()
    let first = ObjectIdentifier(state.pipelineQueue)
    state.ensurePipelineQueue()
    XCTAssertEqual(ObjectIdentifier(state.pipelineQueue), first)
}
```

---

## 8. makePipelineQueue() (4 tests, synchronous)

`makePipelineQueue()` is `internal`, callable via `@testable`. It calls `loadSnapshot()` and `recoverOrphanedRecordings()` — both are harmless if the recordings directory doesn't exist.

| Test | Expected |
|---|---|
| `testMakePipelineQueueHasWhisperKit` | `queue.whisperKit != nil` |
| `testMakePipelineQueueHasDiarizationFactory` | `queue.diarizationFactory != nil` |
| `testMakePipelineQueueHasProtocolGeneratorFactory` | `queue.protocolGeneratorFactory != nil` |
| `testMakePipelineQueueSetsOutputDir` | `queue.outputDir != nil` |

---

## 9. makeProtocolGenerator() (2 tests, synchronous)

| Test | Setup | Expected |
|---|---|---|
| `testMakeProtocolGeneratorOpenAI` | `settings.protocolProvider = .openAICompatible` | `gen is OpenAIProtocolGenerator` |
| `testMakeProtocolGeneratorClaudeCLI` (`#if !APPSTORE`) | `settings.protocolProvider = .claudeCLI` | `gen is ClaudeCLIProtocolGenerator` |

```swift
func testMakeProtocolGeneratorOpenAI() {
    let settings = AppSettings()
    settings.protocolProvider = .openAICompatible
    let state = AppState(settings: settings)
    XCTAssertTrue(state.makeProtocolGenerator() is OpenAIProtocolGenerator)
}

#if !APPSTORE
func testMakeProtocolGeneratorClaudeCLI() {
    let settings = AppSettings()
    settings.protocolProvider = .claudeCLI
    let state = AppState(settings: settings)
    XCTAssertTrue(state.makeProtocolGenerator() is ClaudeCLIProtocolGenerator)
}
#endif
```

---

## 10. configurePipelineCallbacks() (3 tests, synchronous)

Call `configurePipelineCallbacks()` to wire the closure, then trigger state transitions directly via `pipelineQueue.onJobStateChange?(job, oldState, newState)` — no real processing needed.

Use `makeIsolatedState(logDir:)` (section 1.4) to avoid writing queue snapshots to the real filesystem.

| Test | Transition | Expected notification |
|---|---|---|
| `testConfigurePipelineCallbacksDoneFiresNotification` | `→ .done` | `("Protocol Ready", jobTitle)` |
| `testConfigurePipelineCallbacksErrorFiresNotification` | `→ .error` with error string | `("Error", errorString)` |
| `testConfigurePipelineCallbacksTranscribingNoNotification` | `→ .transcribing` | no notification |

```swift
func testConfigurePipelineCallbacksDoneFiresNotification() throws {
    let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tmpDir) }

    let (state, notifier) = makeIsolatedState(logDir: tmpDir)
    state.configurePipelineCallbacks()

    let job = PipelineJob(
        meetingTitle: "Sprint Review",
        appName: "TestApp",
        mixPath: URL(fileURLWithPath: "/tmp/mix.wav"),
        appPath: nil, micPath: nil, micDelay: 0,
    )
    // Trigger the callback directly
    state.pipelineQueue.onJobStateChange?(job, .transcribing, .done)

    XCTAssertEqual(notifier.calls.count, 1)
    XCTAssertEqual(notifier.calls[0].title, "Protocol Ready")
    XCTAssertEqual(notifier.calls[0].body, "Sprint Review")
}
```

---

## 11. Async Test Pattern

All async tests must be `@MainActor` (the class already is). Use `await Task.yield()` to let spawned tasks run. Always clean up active loops with `addTeardownBlock { state.watchLoop?.stop() }`.

```swift
// Standard async test pattern
func testSomeAsyncBehavior() async {
    let (state, _) = makeState()
    addTeardownBlock { state.watchLoop?.stop() }

    state.someMethodThatSpawnsATask()
    await Task.yield()

    XCTAssertNotNil(state.something)
}
```

Never use `XCTestExpectation` or `sleep` — Swift concurrency primitives only.

---

## 12. Implementation Order

Build confidence incrementally:

1. **TestHelpers.swift**: add `makeSilentDetector()`, `makeTestWatchLoop()`, move `RecordingNotifier` there
2. **enqueueFiles** (section 6) — synchronous, zero dependencies, fastest feedback
3. **configurePipelineCallbacks** (section 10) — synchronous, validates notification wiring
4. **isWatching / currentStateLabel / currentStatus** (sections 2.1–2.3) — needs `makeTestWatchLoop`
5. **toggleWatching stop-path** (section 3.2) — synchronous, needs active loop
6. **ensurePipelineQueue / makePipelineQueue / makeProtocolGenerator** (sections 7–9)
7. **toggleWatching start-path** (section 3.3) — async, environment-sensitive
8. **startManualRecording / stopManualRecording** (sections 4–5) — leave for last

---

## 13. Summary

| Group | New tests |
|---|---|
| isWatching | 3 |
| currentStateLabel | 3 |
| currentStatus | 6 |
| toggleWatching (stop) | 2 |
| toggleWatching (start, async) | 2 |
| startManualRecording | 3 |
| stopManualRecording | 2 |
| enqueueFiles | 6 |
| ensurePipelineQueue | 2 |
| makePipelineQueue | 4 |
| makeProtocolGenerator | 2 (+1 conditional) |
| configurePipelineCallbacks | 3 |
| **Total** | **39** |
