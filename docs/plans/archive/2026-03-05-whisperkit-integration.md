# WhisperKit Integration — Native Swift Transcription

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Replace Python-based pywhispercpp transcription with WhisperKit (native Swift) in the MeetingTranscriber menu bar app, eliminating the Python dependency for transcription.

**Architecture:** Add WhisperKit as SPM dependency. Create a new `TranscriptionEngine` that wraps WhisperKit and produces the same `[HH:MM:SS] text` output format the Python pipeline uses. The Swift app gets a new setting to choose engine (Python vs. WhisperKit). When WhisperKit is selected, transcription runs natively in Swift — only diarization + protocol generation still call Python.

**Tech Stack:** WhisperKit (SPM), CoreML, Swift 5.10, macOS 14+

---

## Phase 1: WhisperKit SPM Integration + Basic Transcription

### Task 1: Add WhisperKit SPM Dependency

**Files:**
- Modify: `app/MeetingTranscriber/Package.swift`

**Step 1: Add WhisperKit dependency**

```swift
// swift-tools-version: 5.10

import PackageDescription

let package = Package(
    name: "MeetingTranscriber",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/nalexn/ViewInspector", from: "0.10.0"),
        .package(url: "https://github.com/argmaxinc/WhisperKit.git", from: "0.9.0"),
    ],
    targets: [
        .executableTarget(
            name: "MeetingTranscriber",
            dependencies: [
                .product(name: "WhisperKit", package: "WhisperKit"),
            ],
            path: "Sources",
            exclude: ["Info.plist"]
        ),
        .testTarget(
            name: "MeetingTranscriberTests",
            dependencies: ["MeetingTranscriber", "ViewInspector"],
            path: "Tests"
        ),
    ]
)
```

**Step 2: Verify it resolves and builds**

Run:
```bash
cd app/MeetingTranscriber && swift package resolve && swift build 2>&1 | tail -5
```
Expected: Build succeeds (WhisperKit + dependencies download)

**Step 3: Commit**

```bash
cd /Users/roman/git/Transcriber
git add app/MeetingTranscriber/Package.swift
git commit -m "build(app): add WhisperKit SPM dependency"
```

---

### Task 2: Create WhisperKitEngine — Model Management

**Files:**
- Create: `app/MeetingTranscriber/Sources/WhisperKitEngine.swift`
- Test: `app/MeetingTranscriber/Tests/WhisperKitEngineTests.swift`

**Step 1: Write tests for model state management**

```swift
import XCTest
@testable import MeetingTranscriber

final class WhisperKitEngineTests: XCTestCase {

    func testDefaultModel() {
        let engine = WhisperKitEngine()
        XCTAssertEqual(engine.modelVariant, "openai_whisper-large-v3-v20240930_turbo")
    }

    func testModelStateStartsUnloaded() {
        let engine = WhisperKitEngine()
        XCTAssertEqual(engine.modelState, .unloaded)
    }

    func testLanguageDefault() {
        let engine = WhisperKitEngine()
        XCTAssertNil(engine.language, "Should auto-detect by default")
    }

    func testSetLanguage() {
        let engine = WhisperKitEngine()
        engine.language = "de"
        XCTAssertEqual(engine.language, "de")
    }
}
```

**Step 2: Run tests to verify they fail**

Run: `cd app/MeetingTranscriber && swift test 2>&1 | grep -E "FAIL|error|WhisperKit"`
Expected: Compilation error — `WhisperKitEngine` not found

**Step 3: Implement WhisperKitEngine**

```swift
import Foundation
import WhisperKit

enum WhisperModelState: Equatable {
    case unloaded
    case downloading(progress: Double)
    case loading
    case ready
    case error(String)
}

@Observable
final class WhisperKitEngine {
    var modelVariant = "openai_whisper-large-v3-v20240930_turbo"
    var language: String?
    private(set) var modelState: WhisperModelState = .unloaded
    private var pipe: WhisperKit?

    func loadModel() async {
        modelState = .loading
        do {
            pipe = try await WhisperKit(
                WhisperKitConfig(model: modelVariant)
            )
            modelState = .ready
        } catch {
            modelState = .error(error.localizedDescription)
        }
    }

    func unloadModel() {
        pipe = nil
        modelState = .unloaded
    }

    /// Transcribe a WAV file. Returns lines in `[MM:SS] text` format.
    func transcribe(audioPath: URL) async throws -> String {
        guard let pipe else {
            throw TranscriptionError.modelNotLoaded
        }

        let options = DecodingOptions(
            language: language,
            wordTimestamps: false
        )

        guard let results = try await pipe.transcribe(
            audioPaths: [audioPath.path()],
            decodeOptions: options
        ).first else {
            return ""
        }

        // Flatten and format segments to match Python output: [MM:SS] text
        var lines: [String] = []
        let segments = results?.flatMap { $0.segments } ?? []
        for segment in segments {
            let total = Int(segment.start)
            let h = total / 3600
            let m = (total % 3600) / 60
            let s = total % 60
            let ts = h > 0
                ? String(format: "[%d:%02d:%02d]", h, m, s)
                : String(format: "[%02d:%02d]", m, s)
            let text = segment.text.trimmingCharacters(in: .whitespaces)
            if !text.isEmpty {
                lines.append("\(ts) \(text)")
            }
        }
        return lines.joined(separator: "\n")
    }
}

enum TranscriptionError: LocalizedError {
    case modelNotLoaded

    var errorDescription: String? {
        switch self {
        case .modelNotLoaded: "WhisperKit model not loaded"
        }
    }
}
```

**Step 4: Run tests**

Run: `cd app/MeetingTranscriber && swift test --filter WhisperKitEngineTests 2>&1 | tail -10`
Expected: 4 tests pass

**Step 5: Commit**

```bash
git add app/MeetingTranscriber/Sources/WhisperKitEngine.swift \
       app/MeetingTranscriber/Tests/WhisperKitEngineTests.swift
git commit -m "feat(app): add WhisperKitEngine with model management"
```

---

### Task 3: Integration Test — Transcribe Real Audio

**Files:**
- Modify: `app/MeetingTranscriber/Tests/WhisperKitEngineTests.swift`

**Step 1: Add integration test with test fixture**

```swift
func testTranscribeGermanAudio() async throws {
    // Use existing test fixture
    let fixturePath = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()  // Tests/
        .deletingLastPathComponent()  // MeetingTranscriber/
        .deletingLastPathComponent()  // app/
        .deletingLastPathComponent()  // Transcriber/
        .appendingPathComponent("tests/fixtures/two_speakers_de.wav")

    guard FileManager.default.fileExists(atPath: fixturePath.path) else {
        throw XCTSkip("Test fixture not found: \(fixturePath.path)")
    }

    let engine = WhisperKitEngine()
    // Use small model for faster test
    engine.modelVariant = "openai_whisper-small"
    engine.language = "de"
    await engine.loadModel()
    XCTAssertEqual(engine.modelState, .ready)

    let transcript = try await engine.transcribe(audioPath: fixturePath)
    XCTAssertFalse(transcript.isEmpty, "Transcript should not be empty")
    // Check format: [MM:SS] text
    XCTAssertTrue(transcript.contains("[00:00]"), "Should have timestamp at start")
    // Check it recognized some German
    let lower = transcript.lowercased()
    XCTAssertTrue(
        lower.contains("willkommen") || lower.contains("projekt") || lower.contains("guten"),
        "Should contain German words. Got: \(transcript)"
    )
    print("--- WhisperKit transcript ---")
    print(transcript)
    print("---")
}
```

**Step 2: Run integration test** (will download model on first run, may take a minute)

Run: `cd app/MeetingTranscriber && swift test --filter testTranscribeGermanAudio 2>&1 | tail -20`
Expected: PASS, prints transcript with timestamps

**Step 3: Commit**

```bash
git add app/MeetingTranscriber/Tests/WhisperKitEngineTests.swift
git commit -m "test(app): add WhisperKit German transcription integration test"
```

---

## Phase 2: Settings UI + Engine Selection

### Task 4: Add Engine Setting to AppSettings

**Files:**
- Modify: `app/MeetingTranscriber/Sources/AppSettings.swift`

**Step 1: Read AppSettings.swift to find the whisperModel setting**

Locate the existing `whisperModel` property and understand the UserDefaults pattern used.

**Step 2: Add transcription engine enum and setting**

Add to `AppSettings.swift`:

```swift
enum TranscriptionEngine: String, CaseIterable {
    case python = "python"       // pywhispercpp via Python process
    case whisperKit = "whisperkit" // Native WhisperKit (CoreML)

    var displayName: String {
        switch self {
        case .python: "Whisper (Python)"
        case .whisperKit: "WhisperKit (Native)"
        }
    }
}
```

Add property to `AppSettings`:

```swift
var transcriptionEngine: TranscriptionEngine {
    get {
        TranscriptionEngine(rawValue: UserDefaults.standard.string(forKey: "transcriptionEngine") ?? "") ?? .python
    }
    set {
        UserDefaults.standard.set(newValue.rawValue, forKey: "transcriptionEngine")
    }
}

var whisperKitModel: String {
    get {
        UserDefaults.standard.string(forKey: "whisperKitModel") ?? "openai_whisper-large-v3-v20240930_turbo"
    }
    set {
        UserDefaults.standard.set(newValue, forKey: "whisperKitModel")
    }
}
```

**Step 3: Run existing tests**

Run: `cd app/MeetingTranscriber && swift test 2>&1 | tail -5`
Expected: All tests pass (new settings have safe defaults)

**Step 4: Commit**

```bash
git add app/MeetingTranscriber/Sources/AppSettings.swift
git commit -m "feat(app): add transcription engine selection setting"
```

---

### Task 5: Add Engine Selection to Settings UI

**Files:**
- Modify: `app/MeetingTranscriber/Sources/SettingsView.swift`

**Step 1: Read SettingsView.swift to understand layout**

Find where the Whisper model picker is and add engine selection nearby.

**Step 2: Add engine picker to Settings**

Add a Picker for `TranscriptionEngine` above the existing model selector. When WhisperKit is selected, show the WhisperKit model variant picker instead of the Python whisper model picker. Add a "Download Model" button that shows download progress.

Example UI section:

```swift
Section("Transcription") {
    Picker("Engine", selection: $settings.transcriptionEngine) {
        ForEach(TranscriptionEngine.allCases, id: \.self) { engine in
            Text(engine.displayName).tag(engine)
        }
    }

    if settings.transcriptionEngine == .whisperKit {
        TextField("WhisperKit Model", text: $settings.whisperKitModel)
            .textFieldStyle(.roundedBorder)
        // Model state indicator from WhisperKitEngine
    } else {
        // Existing Python whisper model picker
    }
}
```

**Step 3: Run tests and verify UI**

Run: `cd app/MeetingTranscriber && swift test 2>&1 | tail -5`
Expected: All tests pass

**Step 4: Commit**

```bash
git add app/MeetingTranscriber/Sources/SettingsView.swift
git commit -m "feat(app): add transcription engine picker to settings UI"
```

---

## Phase 3: Native Transcription Pipeline

### Task 6: Modify PythonProcess to Support Split Pipeline

**Files:**
- Modify: `app/MeetingTranscriber/Sources/PythonProcess.swift`
- Modify: `app/MeetingTranscriber/Sources/AppSettings.swift` (buildArguments)

**Context:** When WhisperKit engine is selected, we still need Python for diarization + protocol generation. The flow becomes:

1. Swift app does transcription via WhisperKit → produces transcript text
2. Swift app writes transcript to `~/.meeting-transcriber/transcript.txt`
3. Swift app calls Python with `--transcript-file <path>` flag (skip Whisper, jump to diarization + protocol)

**Step 1: Add `--transcript-file` argument to Python CLI**

Modify `src/meeting_transcriber/cli.py` to accept a `--transcript-file` argument that skips the Whisper step and uses the provided transcript directly. This allows the Swift app to pass pre-transcribed text.

Add to argparse:

```python
parser.add_argument(
    "--transcript-file",
    type=Path,
    help="Path to pre-transcribed text (skip Whisper, go to diarization/protocol)",
)
```

When `--transcript-file` is provided:
- Skip `transcribe()` call
- Read transcript from file
- Continue with diarization (if enabled) and protocol generation

**Step 2: Modify `buildArguments()` in AppSettings**

When engine is `.whisperKit`, omit `--model` and add `--transcript-file <path>` argument.

**Step 3: Add a `NativeTranscriptionManager` to coordinate the split**

```swift
/// Coordinates WhisperKit transcription + Python diarization/protocol.
@Observable
final class NativeTranscriptionManager {
    let engine = WhisperKitEngine()
    private let ipcDir: URL

    init() {
        ipcDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".meeting-transcriber")
    }

    /// Transcribe audio, write result, return path to transcript file.
    func transcribeAndSave(audioPath: URL) async throws -> URL {
        let transcript = try await engine.transcribe(audioPath: audioPath)
        let outputPath = ipcDir.appendingPathComponent("transcript.txt")
        try transcript.write(to: outputPath, atomically: true, encoding: .utf8)
        return outputPath
    }
}
```

**Step 4: Run all tests**

Run:
```bash
cd app/MeetingTranscriber && swift test 2>&1 | tail -5
cd /Users/roman/git/Transcriber && source .venv/bin/activate && pytest tests/ -v -m "not slow" 2>&1 | tail -10
```
Expected: All pass

**Step 5: Commit**

```bash
git add src/meeting_transcriber/cli.py \
       app/MeetingTranscriber/Sources/PythonProcess.swift \
       app/MeetingTranscriber/Sources/AppSettings.swift \
       app/MeetingTranscriber/Sources/NativeTranscriptionManager.swift
git commit -m "feat(app,cli): support split pipeline with --transcript-file flag"
```

---

### Task 7: Wire Up Native Transcription in Watch Flow

**Files:**
- Modify: `app/MeetingTranscriber/Sources/MeetingTranscriberApp.swift` or wherever `toggleWatching()` lives
- Modify: `app/MeetingTranscriber/Sources/StatusMonitor.swift` (if needed)

**Context:** This is the trickiest part. Currently the entire flow (record → transcribe → diarize → protocol) runs in Python. With WhisperKit, the flow becomes:

**Python-only mode** (existing, unchanged):
```
Python: record → transcribe → diarize → protocol
```

**WhisperKit mode** (new):
```
Python: record → emit status "recording_done" with audio_path
Swift:  WhisperKit transcribe → write transcript.txt
Swift:  spawn Python with --transcript-file transcript.txt → diarize → protocol
```

**Step 1: Add new status state for recording completion**

In Python `status.py` / `watcher.py`, emit a new state `recording_done` with the audio file path in the status JSON when recording finishes but before transcription starts. This is only relevant when Swift will handle transcription.

Add a CLI flag `--native-transcription` that makes the watcher emit `recording_done` and wait instead of calling Whisper.

**Step 2: Handle `recording_done` in StatusMonitor**

When StatusMonitor sees `recording_done`, and engine is WhisperKit:
1. Extract audio path from status JSON
2. Call `NativeTranscriptionManager.transcribeAndSave()`
3. Spawn Python with `--transcript-file` for diarization + protocol

**Step 3: Test end-to-end with the test fixture**

Run the app, trigger a short recording, verify WhisperKit transcribes and Python generates the protocol.

**Step 4: Commit**

```bash
git add -p  # stage relevant changes
git commit -m "feat(app): wire native WhisperKit transcription into watch flow"
```

---

### Task 8: CLI Support — `transcribe --engine whisperkit`

**Files:**
- Modify: `src/meeting_transcriber/cli.py`
- Create: `src/meeting_transcriber/transcription/whisperkit.py`

**Context:** For CLI users who want to use `transcribe --file recording.wav` without the menu bar app, add a `--engine` flag that can call a bundled `whisperkit-cli` Swift binary (similar to how we call `audiotap`).

**Step 1: Build a minimal `whisperkit-cli` Swift tool**

Create `tools/whisperkit-cli/` (similar to `tools/audiotap/`):

```swift
// tools/whisperkit-cli/Sources/main.swift
import WhisperKit
import Foundation

// Args: <audio-path> [--language <lang>] [--model <variant>]
// Output: [MM:SS] text lines to stdout
```

**Step 2: Add build script**

Create `scripts/build_whisperkit.sh` (similar to `scripts/build_audiotap.sh`).

**Step 3: Add `--engine` flag to Python CLI**

```python
parser.add_argument(
    "--engine",
    choices=["whisper", "whisperkit"],
    default="whisper",
    help="Transcription engine (default: whisper)",
)
```

When `--engine whisperkit`, call the Swift binary instead of pywhispercpp.

**Step 4: Test**

```bash
./scripts/build_whisperkit.sh
transcribe --file tests/fixtures/two_speakers_de.wav --engine whisperkit --title "Test"
```

**Step 5: Commit**

```bash
git add tools/whisperkit-cli/ scripts/build_whisperkit.sh \
       src/meeting_transcriber/cli.py \
       src/meeting_transcriber/transcription/whisperkit.py
git commit -m "feat(cli): add whisperkit-cli tool and --engine flag"
```

---

## Phase 4: Model Management UX

### Task 9: Model Download Progress in UI

**Files:**
- Modify: `app/MeetingTranscriber/Sources/WhisperKitEngine.swift`
- Modify: `app/MeetingTranscriber/Sources/SettingsView.swift`

**Step 1: Add download progress tracking**

WhisperKit supports progress callbacks during model download. Add to `WhisperKitEngine.loadModel()`:

```swift
func loadModel() async {
    modelState = .downloading(progress: 0)
    do {
        pipe = try await WhisperKit(
            WhisperKitConfig(
                model: modelVariant,
                downloadProgressCallback: { progress in
                    Task { @MainActor in
                        self.modelState = .downloading(progress: progress.fractionCompleted)
                    }
                }
            )
        )
        modelState = .ready
    } catch {
        modelState = .error(error.localizedDescription)
    }
}
```

**Step 2: Show progress bar in SettingsView**

```swift
switch whisperKitEngine.modelState {
case .downloading(let progress):
    ProgressView(value: progress)
        .progressViewStyle(.linear)
    Text("Downloading model... \(Int(progress * 100))%")
case .loading:
    ProgressView()
    Text("Loading model...")
case .ready:
    Label("Model ready", systemImage: "checkmark.circle.fill")
        .foregroundStyle(.green)
case .error(let msg):
    Label(msg, systemImage: "exclamationmark.triangle")
        .foregroundStyle(.red)
case .unloaded:
    Button("Load Model") {
        Task { await whisperKitEngine.loadModel() }
    }
}
```

**Step 3: Commit**

```bash
git add app/MeetingTranscriber/Sources/WhisperKitEngine.swift \
       app/MeetingTranscriber/Sources/SettingsView.swift
git commit -m "feat(app): add model download progress to settings UI"
```

---

### Task 10: Auto-Load Model on App Start

**Files:**
- Modify: `app/MeetingTranscriber/Sources/MeetingTranscriberApp.swift`

**Step 1: Pre-load WhisperKit model when engine is set to whisperKit**

On app launch, if `settings.transcriptionEngine == .whisperKit`, start loading the model in background so it's ready when a meeting is detected.

```swift
.task {
    if settings.transcriptionEngine == .whisperKit {
        await nativeTranscriptionManager.engine.loadModel()
    }
}
```

**Step 2: Commit**

```bash
git add app/MeetingTranscriber/Sources/MeetingTranscriberApp.swift
git commit -m "feat(app): auto-load WhisperKit model on startup"
```

---

## Phase 5: Bundle & Distribution

### Task 11: Update Build Scripts

**Files:**
- Modify: `scripts/build_release.sh`
- Modify: `scripts/run_app.sh`

**Step 1: Ensure WhisperKit models are handled in release build**

WhisperKit downloads models at runtime (no need to bundle). But ensure the app has network entitlement for first-time download. Check `entitlements.plist` for `com.apple.security.network.client`.

**Step 2: Update build_release.sh if needed**

If the `whisperkit-cli` tool from Task 8 needs to be bundled, add it to the build script alongside `audiotap`.

**Step 3: Test release build**

```bash
./scripts/build_release.sh
```

**Step 4: Commit**

```bash
git add scripts/ entitlements.plist
git commit -m "build: update release scripts for WhisperKit support"
```

---

### Task 12: Update Documentation

**Files:**
- Modify: `CLAUDE.md`

**Step 1: Update CLAUDE.md**

Add WhisperKit to the pipeline diagram, document the `--engine` flag, and note the new `TranscriptionEngine` setting.

**Step 2: Commit**

```bash
git add CLAUDE.md
git commit -m "docs: add WhisperKit integration documentation"
```

---

## Summary

| Phase | Tasks | What it delivers |
|-------|-------|-----------------|
| 1 | 1-3 | WhisperKit compiles, transcribes audio, tests pass |
| 2 | 4-5 | User can choose engine in Settings UI |
| 3 | 6-8 | Full pipeline works: WhisperKit transcribe → Python diarize → protocol |
| 4 | 9-10 | Polished model download UX |
| 5 | 11-12 | Distribution-ready, documented |

**Critical path:** Tasks 1-3 → 6-7 (minimum for working E2E)

**Can be deferred:** Task 8 (CLI support), Task 9-10 (UX polish), Task 11-12 (distribution)
