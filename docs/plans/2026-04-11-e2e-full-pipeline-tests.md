# E2E Full Pipeline Tests — Design & Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Test the complete app pipeline end-to-end with zero mocks — real detection, real recording, real transcription (Parakeet), real diarization (FluidDiarizer), real output files.

**Architecture:** The test launches `meeting-simulator` as a subprocess which opens a window (triggers PowerAssertionDetector), plays `two_speakers_de.wav` through the speakers. WatchLoop detects the meeting, CATapDescription taps the simulator's audio, Parakeet transcribes, FluidDiarizer diarizes, and the test verifies the output files.

```
swift test (E2EFullPipelineTests)
  │
  ├── Build meeting-simulator (setUpClass)
  ├── Load Parakeet model (auto-download, ~50 MB)
  │
  ├── testFullPipeline()
  │     │
  │     ├── Start WatchLoop (PowerAssertionDetector + DualSourceRecorder)
  │     ├── Launch meeting-simulator subprocess
  │     │     → Window opens, power assertion created
  │     │     → Plays two_speakers_de.wav (~53s)
  │     │     → Auto-closes after playback
  │     │
  │     ├── WatchLoop detects meeting (via power assertion)
  │     ├── CATapDescription taps simulator PID
  │     ├── Records audio (~53s)
  │     ├── Simulator closes → WatchLoop detects end (grace period)
  │     ├── Pipeline: Parakeet transcription (~5s)
  │     ├── Pipeline: FluidDiarizer (~5s)
  │     ├── Speaker naming: auto-skip
  │     ├── Protocol provider: .none (transcript only)
  │     └── Assert output files
  │
  └── Cleanup temp dir
```

**Total test time:** ~80s (53s recording + 15s grace period + ~10s inference + overhead)

---

## Prerequisites

| Requirement | Why | CI Impact |
|---|---|---|
| macOS 14.2+ | CATapDescription | GitHub runners OK |
| Microphone permission | AVAudioEngine mic recording | **Not available on CI** — test skipped |
| Audio output device | AVAudioPlayer in simulator | Available on macOS runners |
| Parakeet model (~50 MB) | Real transcription | Auto-downloaded, cacheable |
| FluidAudio models (~50 MB) | Real diarization | Auto-downloaded, cacheable |

**CI strategy:** Skip via `XCTSkipIf(ProcessInfo.processInfo.environment["CI"] != nil)`. Run locally or on self-hosted runner with permissions pre-granted.

---

## Task 1: Build Infrastructure

**Files:**
- Modify: `Tests/TestHelpers.swift`

**Step 1: Add meeting-simulator build helper**

```swift
enum SimulatorHelper {
    /// Path to the project root (derived from test file location).
    static let projectRoot: URL = {
        // Tests/E2EFullPipelineTests.swift → Tests/ → MeetingTranscriber/ → app/ → project root
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // Tests/
            .deletingLastPathComponent() // MeetingTranscriber/
            .deletingLastPathComponent() // app/
    }()

    /// Path to the meeting-simulator package.
    static let simulatorPackage = projectRoot.appendingPathComponent("tools/meeting-simulator")

    /// Path to the fixture audio file.
    static let fixtureAudio = projectRoot
        .appendingPathComponent("app/MeetingTranscriber/Tests/Fixtures/two_speakers_de.wav")

    /// Builds the meeting-simulator and returns the path to the executable.
    static func buildSimulator() throws -> URL {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/swift")
        process.arguments = ["build", "-c", "release"]
        process.currentDirectoryURL = simulatorPackage
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            throw NSError(domain: "SimulatorHelper", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Build failed: \(output)"])
        }
        return simulatorPackage
            .appendingPathComponent(".build/release/meeting-simulator")
    }

    /// Launches the meeting-simulator as a subprocess.
    static func launchSimulator(binary: URL, audioPath: URL) throws -> Process {
        let process = Process()
        process.executableURL = binary
        process.arguments = [audioPath.path]
        try process.run()
        return process
    }
}
```

**Step 2: Run existing tests to verify nothing breaks**

Run: `cd app/MeetingTranscriber && swift test --filter WatchLoopE2ETests`

**Step 3: Commit**

```
test(app): add SimulatorHelper for E2E test infrastructure
```

---

## Task 2: Create E2E Test — Full Pipeline

**Files:**
- Create: `Tests/E2EFullPipelineTests.swift`

**Step 1: Write the test file**

```swift
@testable import MeetingTranscriber
import XCTest

@MainActor
final class E2EFullPipelineTests: XCTestCase {
    private static var simulatorBinary: URL!
    private var tmpDir: URL!

    // MARK: - Setup

    override class func setUp() {
        super.setUp()
        // Build meeting-simulator once for all tests in this class
        do {
            simulatorBinary = try SimulatorHelper.buildSimulator()
        } catch {
            XCTFail("Failed to build meeting-simulator: \(error)")
        }
    }

    override func setUp() async throws {
        // Skip in CI — needs mic permission + audio hardware
        try XCTSkipIf(
            ProcessInfo.processInfo.environment["CI"] != nil,
            "E2E test requires audio hardware and mic permission"
        )

        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("e2e_pipeline_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tmpDir)
    }

    // MARK: - Full Pipeline Test

    func testFullPipelineDetectRecordTranscribeDiarize() async throws {
        // 1. Set up real Parakeet engine
        let engine = ParakeetEngine()
        try await engine.loadModel()

        // 2. Create pipeline queue with real components
        let diarizer = FluidDiarizer()
        let queue = PipelineQueue(
            engine: engine,
            diarizationFactory: { diarizer },
            protocolGeneratorFactory: { nil }, // .none provider — transcript only
            outputDir: tmpDir,
            logDir: tmpDir,
            diarizeEnabled: true,
            numSpeakers: 2,
            micLabel: "Me",
        )

        // Auto-skip speaker naming
        queue.speakerNamingHandler = { _ in .skipped }

        // 3. Track completion
        let pipelineDone = expectation(description: "Pipeline completes")
        queue.onJobStateChange = { _, _, newState in
            if newState == .done || newState == .error {
                pipelineDone.fulfill()
            }
        }

        // 4. Create WatchLoop with real detector + real recorder
        let detector = PowerAssertionDetector()
        let loop = WatchLoop(
            detector: detector,
            recorderFactory: { DualSourceRecorder() },
            pipelineQueue: queue,
            pollInterval: 1.0,
            endGracePeriod: 5.0,
        )

        // 5. Start watching
        loop.start()
        addTeardownBlock { loop.stop() }

        // 6. Launch meeting simulator
        let simulator = try SimulatorHelper.launchSimulator(
            binary: Self.simulatorBinary,
            audioPath: SimulatorHelper.fixtureAudio,
        )
        addTeardownBlock { simulator.terminate() }

        // 7. Wait for pipeline to complete (timeout: 120s)
        // ~53s audio + 5s grace + model loading + inference
        await fulfillment(of: [pipelineDone], timeout: 120)

        // 8. Assertions
        let job = try XCTUnwrap(queue.jobs.first)
        XCTAssertEqual(job.state, .done, "Job should complete. Error: \(job.error ?? "none")")
        XCTAssertNil(job.error)

        // Transcript file exists
        let transcriptPath = try XCTUnwrap(job.transcriptPath)
        XCTAssertTrue(FileManager.default.fileExists(atPath: transcriptPath.path),
                      "Transcript file should exist at \(transcriptPath.path)")

        // Transcript has content
        let transcript = try String(contentsOf: transcriptPath, encoding: .utf8)
        XCTAssertFalse(transcript.isEmpty, "Transcript should not be empty")

        // Audio was actually recorded (mix file should exist)
        XCTAssertNotNil(job.mixPath)
        if let mixPath = job.mixPath {
            XCTAssertTrue(FileManager.default.fileExists(atPath: mixPath.path),
                          "Mix audio file should exist")
        }

        print("=== E2E Test Passed ===")
        print("Transcript length: \(transcript.count) chars")
        print("Transcript preview: \(String(transcript.prefix(200)))")
    }
}
```

**Step 2: Run the test locally**

```bash
cd app/MeetingTranscriber && swift test --filter E2EFullPipelineTests
```

Expected: Takes ~80–120s. Meeting simulator window opens, audio plays, app detects and records, pipeline runs, test passes.

Potential issues to debug:
- Mic permission prompt → grant to Terminal/Xcode
- PowerAssertionDetector doesn't detect the simulator → check assertion naming pattern
- CATapDescription can't tap the simulator → check PID passing
- Audio too quiet → CATapDescription captures system audio, volume doesn't matter

**Step 3: Commit**

```
test(app): add E2E full pipeline test with real detection, recording, and transcription
```

---

## Task 3: CI Integration

**Files:**
- Modify: `.github/workflows/ci.yml`

**Step 1: Add `--skip` for E2E tests in normal CI**

In the test step, change:
```yaml
swift test ${{ matrix.swift-flags }}
```
to:
```yaml
swift test --skip E2EFullPipeline ${{ matrix.swift-flags }}
```

**Step 2: Commit**

```
ci: skip E2E full pipeline tests in CI (requires audio hardware)
```

---

## Task 4: Verify & Polish

**Step 1: Run full test suite locally**

```bash
cd app/MeetingTranscriber && swift test
```

Expected: All tests pass including E2E (~993 existing + 1 new). E2E test takes ~80–120s.

**Step 2: Run lint**

```bash
./scripts/lint.sh
```

**Step 3: Verify CI still works**

Push to a branch, confirm the `--skip` flag correctly skips the E2E test while all other tests pass.

---

## Future Extensions

Once the basic E2E test works, possible additions:

| Test | What it adds |
|---|---|
| `testFullPipelineDualSource` | Verify both app + mic tracks are recorded and merged |
| `testFullPipelineWithSpeakerNaming` | Use `.confirmed()` instead of `.skipped`, verify names in output |
| `testFullPipelineShortAudio` | Use a shorter fixture (~10s) for faster feedback |
| `testFullPipelineWhisperKit` | Same test but with WhisperKit engine |
| Self-hosted CI job | Run E2E on Tart VM or self-hosted Mac runner on tag push |

---

## Summary

| Item | Detail |
|---|---|
| Test file | `Tests/E2EFullPipelineTests.swift` |
| Mocks | **None** — everything real |
| Engine | Parakeet (fastest, ~50 MB model) |
| Diarization | FluidDiarizer (offline mode) |
| Protocol | `.none` (transcript only) |
| Speaker naming | Auto-skip |
| Audio | `two_speakers_de.wav` fixture via meeting-simulator |
| Duration | ~80–120s |
| CI | Skipped via `--skip E2EFullPipeline` |
| Local | `swift test --filter E2EFullPipeline` |
