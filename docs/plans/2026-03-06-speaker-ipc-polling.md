# Speaker IPC Polling Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Automatically show speaker count and speaker naming dialogs when diarize.py writes IPC request files during the diarization phase.

**Architecture:** Add an `IPCPoller` that watches `~/.meeting-transcriber/` for `speaker_count_request.json` and `speaker_request.json` during diarization. When a file appears, the app opens the corresponding SwiftUI dialog window. When the user confirms, the response JSON is written and diarize.py continues. The poller runs only while `WatchLoop.state == .diarizing` (new state) or during `handleMeeting()`.

**Tech Stack:** Swift, Foundation (Timer/FileManager polling), SwiftUI window management

---

### Task 1: Add `.diarizing` state to WatchLoop

**Files:**
- Modify: `app/MeetingTranscriber/Sources/WatchLoop.swift:11-19` (State enum)
- Modify: `app/MeetingTranscriber/Sources/WatchLoop.swift:344-353` (transcriberState mapping)

**Step 1: Add diarizing to State enum**

In `WatchLoop.State`, add `diarizing` after `transcribing`:

```swift
enum State: String, Sendable {
    case idle
    case watching
    case recording
    case transcribing
    case diarizing
    case generatingProtocol
    case done
    case error
}
```

**Step 2: Map diarizing to TranscriberState**

In `transcriberState` computed property, add:

```swift
case .diarizing: .transcribing  // reuse transcribing icon for now
```

**Step 3: Use transition in handleMeeting**

In `handleMeeting()`, before the diarization block (`if diarizeEnabled {`), change:

```swift
if diarizeProcess.isAvailable {
    transition(to: .diarizing)
    detail = "Diarizing: \(title)"
```

(Replace the existing `detail = "Diarizing: \(title)"` line with transition + detail.)

**Step 4: Run tests**

Run: `cd app/MeetingTranscriber && swift test --filter "WatchLoop" 2>&1 | tail -5`
Expected: All WatchLoop tests pass (update any tests that check state transitions if needed).

**Step 5: Commit**

```bash
git add app/MeetingTranscriber/Sources/WatchLoop.swift
git commit -m "feat(app): add .diarizing state to WatchLoop"
```

---

### Task 2: Create IPCPoller class

**Files:**
- Create: `app/MeetingTranscriber/Sources/IPCPoller.swift`
- Test: `app/MeetingTranscriber/Tests/IPCPollerTests.swift`

**Step 1: Write the test**

```swift
import XCTest
@testable import MeetingTranscriber

final class IPCPollerTests: XCTestCase {
    private var tmpDir: URL!
    private var poller: IPCPoller!

    override func setUp() async throws {
        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ipc_poller_test_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        poller = IPCPoller(ipcDir: tmpDir, pollInterval: 0.1)
    }

    override func tearDown() async throws {
        poller.stop()
        try? FileManager.default.removeItem(at: tmpDir)
    }

    func testDetectsSpeakerCountRequest() async throws {
        let expectation = XCTestExpectation(description: "speaker count request detected")
        var receivedRequest: SpeakerCountRequest?

        poller.onSpeakerCountRequest = { request in
            receivedRequest = request
            expectation.fulfill()
        }
        poller.start()

        // Write request file
        let request = SpeakerCountRequest(version: 1, timestamp: "2026-03-06T12:00:00", meetingTitle: "Test")
        let data = try JSONEncoder().encode(request)
        try data.write(to: tmpDir.appendingPathComponent("speaker_count_request.json"))

        await fulfillment(of: [expectation], timeout: 2.0)
        XCTAssertEqual(receivedRequest?.meetingTitle, "Test")
    }

    func testDetectsSpeakerRequest() async throws {
        let expectation = XCTestExpectation(description: "speaker request detected")
        var receivedRequest: SpeakerRequest?

        poller.onSpeakerRequest = { request in
            receivedRequest = request
            expectation.fulfill()
        }
        poller.start()

        // Write request file
        let request = SpeakerRequest(
            version: 1, timestamp: "2026-03-06T12:00:00",
            meetingTitle: "Test", audioSamplesDir: "/tmp",
            speakers: [SpeakerInfo(label: "SPEAKER_00", autoName: "Alice",
                                   confidence: 0.9, speakingTimeSeconds: 30, sampleFile: "s0.wav")]
        )
        let data = try JSONEncoder().encode(request)
        try data.write(to: tmpDir.appendingPathComponent("speaker_request.json"))

        await fulfillment(of: [expectation], timeout: 2.0)
        XCTAssertEqual(receivedRequest?.speakers.count, 1)
    }

    func testDoesNotFireWhenStopped() async throws {
        var called = false
        poller.onSpeakerCountRequest = { _ in called = true }
        // Don't start the poller

        let request = SpeakerCountRequest(version: 1, timestamp: "2026-03-06T12:00:00", meetingTitle: "Test")
        let data = try JSONEncoder().encode(request)
        try data.write(to: tmpDir.appendingPathComponent("speaker_count_request.json"))

        try await Task.sleep(for: .milliseconds(300))
        XCTAssertFalse(called)
    }

    func testDoesNotFireTwiceForSameFile() async throws {
        var callCount = 0
        let expectation = XCTestExpectation(description: "called once")

        poller.onSpeakerCountRequest = { _ in
            callCount += 1
            expectation.fulfill()
        }
        poller.start()

        let request = SpeakerCountRequest(version: 1, timestamp: "2026-03-06T12:00:00", meetingTitle: "Test")
        let data = try JSONEncoder().encode(request)
        try data.write(to: tmpDir.appendingPathComponent("speaker_count_request.json"))

        await fulfillment(of: [expectation], timeout: 2.0)
        // Wait a bit more to ensure no duplicate
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertEqual(callCount, 1)
    }
}
```

**Step 2: Run test to verify it fails**

Run: `cd app/MeetingTranscriber && swift test --filter "IPCPoller" 2>&1 | tail -5`
Expected: FAIL — `IPCPoller` not defined.

**Step 3: Implement IPCPoller**

Create `app/MeetingTranscriber/Sources/IPCPoller.swift`:

```swift
import Foundation

/// Polls the IPC directory for speaker request files from diarize.py.
/// Fires callbacks on the main thread when requests appear.
class IPCPoller {
    private let ipcDir: URL
    private let pollInterval: TimeInterval
    private var timer: Timer?
    private var seenFiles: Set<String> = []

    var onSpeakerCountRequest: ((SpeakerCountRequest) -> Void)?
    var onSpeakerRequest: ((SpeakerRequest) -> Void)?

    init(
        ipcDir: URL? = nil,
        pollInterval: TimeInterval = 1.0
    ) {
        self.ipcDir = ipcDir ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".meeting-transcriber")
        self.pollInterval = pollInterval
    }

    func start() {
        stop()
        seenFiles.removeAll()
        timer = Timer.scheduledTimer(withTimeInterval: pollInterval, repeats: true) { [weak self] _ in
            self?.poll()
        }
        // Also poll immediately
        poll()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func poll() {
        checkFile("speaker_count_request.json") { (request: SpeakerCountRequest) in
            self.onSpeakerCountRequest?(request)
        }
        checkFile("speaker_request.json") { (request: SpeakerRequest) in
            self.onSpeakerRequest?(request)
        }
    }

    private func checkFile<T: Decodable>(_ filename: String, handler: (T) -> Void) {
        guard !seenFiles.contains(filename) else { return }
        let url = ipcDir.appendingPathComponent(filename)
        guard let data = try? Data(contentsOf: url),
              let request = try? JSONDecoder().decode(T.self, from: data) else { return }
        seenFiles.insert(filename)
        handler(request)
    }

    /// Reset seen files (call after diarization completes to allow next session).
    func reset() {
        seenFiles.removeAll()
    }
}
```

**Step 4: Run tests**

Run: `cd app/MeetingTranscriber && swift test --filter "IPCPoller" 2>&1 | tail -5`
Expected: All 4 tests PASS.

**Step 5: Commit**

```bash
git add app/MeetingTranscriber/Sources/IPCPoller.swift app/MeetingTranscriber/Tests/IPCPollerTests.swift
git commit -m "feat(app): add IPCPoller for diarization speaker dialogs"
```

---

### Task 3: Wire IPCPoller into MeetingTranscriberApp

**Files:**
- Modify: `app/MeetingTranscriber/Sources/MeetingTranscriberApp.swift`

**Step 1: Add IPCPoller property and start/stop lifecycle**

Add to `MeetingTranscriberApp`:

```swift
private let ipcPoller = IPCPoller()
```

**Step 2: Configure callbacks in toggleWatching()**

After creating the `WatchLoop`, configure the IPC poller callbacks. In the `await MainActor.run { ... }` block, after `watchLoop = loop` and before `loop.start()`:

```swift
// IPC polling for speaker dialogs during diarization
ipcPoller.onSpeakerCountRequest = { [weak self] request in
    guard let self else { return }
    self.speakerCountRequest = request
    NSApp.activate()
    openWindow(id: "speaker-count")
}
ipcPoller.onSpeakerRequest = { [weak self] request in
    guard let self else { return }
    self.speakerRequest = request
    NSApp.activate()
    openWindow(id: "speaker-naming")
}
```

**Step 3: Start/stop poller based on WatchLoop state**

In the `loop.onStateChange` callback, add:

```swift
case .diarizing:
    self?.ipcPoller.start()
default:
    break
```

And at the end of the switch (after the existing cases), in `.done` and `.error`:

```swift
case .done:
    notifications.notify(title: "Protocol Ready", body: "Protocol is ready.")
    self?.ipcPoller.stop()
    self?.ipcPoller.reset()
case .error:
    if let err = loop.lastError {
        notifications.notify(title: "Error", body: err)
    }
    self?.ipcPoller.stop()
    self?.ipcPoller.reset()
```

Wait — but `self` is the struct `MeetingTranscriberApp`, which can't be captured weakly. The `ipcPoller` is a `let` constant accessible in the closure scope. Adjust:

```swift
loop.onStateChange = { [notifications, ipcPoller] _, newState in
    switch newState {
    case .recording:
        if let meeting = loop.currentMeeting {
            notifications.notify(title: "Meeting Detected", body: "Recording: \(meeting.windowTitle)")
        }
    case .diarizing:
        ipcPoller.start()
    case .done:
        ipcPoller.stop()
        ipcPoller.reset()
        notifications.notify(title: "Protocol Ready", body: "Protocol is ready.")
    case .error:
        ipcPoller.stop()
        ipcPoller.reset()
        if let err = loop.lastError {
            notifications.notify(title: "Error", body: err)
        }
    default:
        break
    }
}
```

**Step 4: Handle openWindow for speaker dialogs**

The `openWindow(id:)` calls need `@Environment(\.openWindow)` which is only available in the view body. Since the callbacks fire from a Timer (not SwiftUI), we need to use `NotificationCenter` like we did for auto-watch.

Add two more notification names:

```swift
extension Notification.Name {
    static let showSpeakerCount = Notification.Name("showSpeakerCount")
    static let showSpeakerNaming = Notification.Name("showSpeakerNaming")
}
```

Change the IPC callbacks to post notifications:

```swift
ipcPoller.onSpeakerCountRequest = { request in
    DispatchQueue.main.async {
        speakerCountRequest = request
        NotificationCenter.default.post(name: .showSpeakerCount, object: nil)
    }
}
ipcPoller.onSpeakerRequest = { request in
    DispatchQueue.main.async {
        speakerRequest = request
        NotificationCenter.default.post(name: .showSpeakerNaming, object: nil)
    }
}
```

Add `.onReceive` handlers in the body (on the MenuBarExtra label, next to the existing auto-watch one):

```swift
.onReceive(NotificationCenter.default.publisher(for: .showSpeakerCount)) { _ in
    NSApp.activate()
    openWindow(id: "speaker-count")
}
.onReceive(NotificationCenter.default.publisher(for: .showSpeakerNaming)) { _ in
    NSApp.activate()
    openWindow(id: "speaker-naming")
}
```

**Step 5: Remove manual "Name Speakers" menu trigger**

In `MenuBarView`, the manual `onNameSpeakers` callback can stay as a fallback, but the IPC-based trigger is now automatic.

**Step 6: Build and verify**

Run: `cd app/MeetingTranscriber && swift build -c release 2>&1 | tail -3`
Expected: Build complete.

**Step 7: Commit**

```bash
git add app/MeetingTranscriber/Sources/MeetingTranscriberApp.swift
git commit -m "feat(app): wire IPCPoller to show speaker dialogs during diarization"
```

---

### Task 4: Clean up IPC files after diarization

**Files:**
- Modify: `app/MeetingTranscriber/Sources/WatchLoop.swift` (after diarization block)

**Step 1: Add IPC cleanup after diarization**

After the diarization `} else { ... }` block closes (after line ~260), add cleanup:

```swift
// Clean up IPC files from diarize.py
let ipcDir = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent(".meeting-transcriber")
for name in ["speaker_request.json", "speaker_response.json",
             "speaker_count_request.json", "speaker_count_response.json"] {
    try? FileManager.default.removeItem(at: ipcDir.appendingPathComponent(name))
}
```

**Step 2: Build and verify**

Run: `cd app/MeetingTranscriber && swift build -c release 2>&1 | tail -3`
Expected: Build complete.

**Step 3: Commit**

```bash
git add app/MeetingTranscriber/Sources/WatchLoop.swift
git commit -m "chore(app): clean up IPC files after diarization"
```

---

### Task 5: E2E test with meeting simulator

**Step 1: Run full pipeline test**

```bash
# Kill any existing app
pkill -f MeetingTranscriber; true
rm -rf app/MeetingTranscriber/.build/MeetingTranscriber-Dev.app
rm -f ~/Library/Application\ Support/MeetingTranscriber/watchloop.log

# Rebuild
cd app/MeetingTranscriber && swift build -c release

# Start app (auto-watch enabled)
cd ../.. && ./scripts/run_app.sh > /tmp/run_app.log 2>&1 &
sleep 20

# Start simulator
./tools/meeting-simulator/.build/release/meeting-simulator &
```

**Step 2: Verify pipeline**

Wait for audio to finish (~50s), then check:
- `watchloop.log` shows: detected → recording → transcribing → diarizing → done
- Speaker count dialog appeared (if diarize.py writes it)
- Speaker naming dialog appeared (if diarize.py writes it)
- Protocol file created with speaker names

**Step 3: Run unit tests**

Run: `cd app/MeetingTranscriber && swift test 2>&1 | tail -5`
Expected: All tests pass.

**Step 4: Commit any fixes**

---

### Task 6: Remove debug logging

**Files:**
- Modify: `app/MeetingTranscriber/Sources/WatchLoop.swift` (remove debugWrite calls and debugLog/debugWrite methods)
- Modify: `app/MeetingTranscriber/Sources/MeetingTranscriberApp.swift` (remove NSLog debug lines)
- Modify: `app/MeetingTranscriber/Sources/MeetingDetector.swift` (remove patternNames if unused)

**Step 1: Clean up debug code**

Remove `debugWrite()`, `debugLog`, `patternNames`, and NSLog debug lines added during debugging. Keep the file-based error.log write for real errors.

**Step 2: Build and test**

Run: `cd app/MeetingTranscriber && swift test 2>&1 | tail -5`
Expected: All tests pass.

**Step 3: Commit**

```bash
git add -u app/MeetingTranscriber/Sources/
git commit -m "chore(app): remove debug logging from WatchLoop"
```
