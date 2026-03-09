# Native Diarization Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Replace Python pyannote subprocess with FluidAudio (native Swift CoreML diarization), eliminating the 700 MB Python bundle and HuggingFace token requirement.

**Architecture:** FluidAudio SPM package provides `OfflineDiarizerManager` which runs pyannote segmentation + WeSpeaker embeddings on CoreML/ANE. A new `FluidDiarizer` class implements the existing `DiarizationProvider` protocol. Speaker matching moves from Python into a new `SpeakerMatcher` Swift class. The IPC file polling mechanism is replaced by direct async continuation — the pipeline suspends until the user closes the speaker-naming popup.

**Tech Stack:** FluidAudio (SPM), CoreML, Swift concurrency (async/await + CheckedContinuation)

---

### Task 1: Add FluidAudio SPM dependency

**Files:**
- Modify: `app/MeetingTranscriber/Package.swift`

**Step 1: Add FluidAudio to Package.swift**

```swift
// In dependencies array, add:
.package(url: "https://github.com/FluidInference/FluidAudio.git", from: "0.12.2"),

// In executableTarget dependencies, add:
.product(name: "FluidAudio", package: "FluidAudio"),
```

The full Package.swift should be:

```swift
// swift-tools-version: 5.10

import PackageDescription

let package = Package(
    name: "MeetingTranscriber",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/nalexn/ViewInspector", from: "0.10.0"),
        .package(url: "https://github.com/argmaxinc/WhisperKit.git", from: "0.9.0"),
        .package(url: "https://github.com/FluidInference/FluidAudio.git", from: "0.12.2"),
    ],
    targets: [
        .executableTarget(
            name: "MeetingTranscriber",
            dependencies: [
                .product(name: "WhisperKit", package: "WhisperKit"),
                .product(name: "FluidAudio", package: "FluidAudio"),
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

Run: `cd app/MeetingTranscriber && swift package resolve && swift build`
Expected: Build succeeds (FluidAudio downloads, compiles with C++17 FastCluster)

**Step 3: Commit**

```bash
git add app/MeetingTranscriber/Package.swift app/MeetingTranscriber/Package.resolved
git commit -m "build(app): add FluidAudio SPM dependency for native diarization"
```

---

### Task 2: Create SpeakerMatcher (speaker recognition + DB)

**Files:**
- Create: `app/MeetingTranscriber/Sources/SpeakerMatcher.swift`
- Create: `app/MeetingTranscriber/Tests/SpeakerMatcherTests.swift`

**Step 1: Write the tests**

```swift
import XCTest
@testable import MeetingTranscriber

final class SpeakerMatcherTests: XCTestCase {
    var tmpDir: URL!
    var dbPath: URL!

    override func setUp() {
        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SpeakerMatcherTests-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        dbPath = tmpDir.appendingPathComponent("speakers.json")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tmpDir)
    }

    // MARK: - Cosine distance

    func testCosineDistanceIdentical() {
        let a: [Float] = [1, 0, 0]
        let b: [Float] = [1, 0, 0]
        XCTAssertEqual(SpeakerMatcher.cosineDistance(a, b), 0, accuracy: 0.001)
    }

    func testCosineDistanceOpposite() {
        let a: [Float] = [1, 0, 0]
        let b: [Float] = [-1, 0, 0]
        XCTAssertEqual(SpeakerMatcher.cosineDistance(a, b), 2, accuracy: 0.001)
    }

    func testCosineDistanceOrthogonal() {
        let a: [Float] = [1, 0, 0]
        let b: [Float] = [0, 1, 0]
        XCTAssertEqual(SpeakerMatcher.cosineDistance(a, b), 1, accuracy: 0.001)
    }

    // MARK: - Match

    func testMatchEmptyDB() {
        let matcher = SpeakerMatcher(dbPath: dbPath)
        let embeddings: [String: [Float]] = ["SPEAKER_0": [1, 0, 0]]
        let result = matcher.match(embeddings: embeddings)
        // No stored speakers → all unmatched, labels stay as-is
        XCTAssertEqual(result["SPEAKER_0"], "SPEAKER_0")
    }

    func testMatchKnownSpeaker() {
        // Store a speaker
        let matcher = SpeakerMatcher(dbPath: dbPath)
        let stored = [StoredSpeaker(name: "Roman", embedding: [1, 0, 0])]
        matcher.saveDB(stored)

        // Match with similar embedding
        let embeddings: [String: [Float]] = ["SPEAKER_0": [0.99, 0.01, 0]]
        let result = matcher.match(embeddings: embeddings)
        XCTAssertEqual(result["SPEAKER_0"], "Roman")
    }

    func testMatchTwoSpeakersNoConflict() {
        let matcher = SpeakerMatcher(dbPath: dbPath)
        let stored = [
            StoredSpeaker(name: "Roman", embedding: [1, 0, 0]),
            StoredSpeaker(name: "Anna", embedding: [0, 1, 0]),
        ]
        matcher.saveDB(stored)

        let embeddings: [String: [Float]] = [
            "SPEAKER_0": [0.99, 0.01, 0],
            "SPEAKER_1": [0.01, 0.99, 0],
        ]
        let result = matcher.match(embeddings: embeddings)
        XCTAssertEqual(result["SPEAKER_0"], "Roman")
        XCTAssertEqual(result["SPEAKER_1"], "Anna")
    }

    func testMatchBelowThresholdStaysUnmatched() {
        let matcher = SpeakerMatcher(dbPath: dbPath, threshold: 0.3)
        let stored = [StoredSpeaker(name: "Roman", embedding: [1, 0, 0])]
        matcher.saveDB(stored)

        // Orthogonal = distance 1.0, above threshold
        let embeddings: [String: [Float]] = ["SPEAKER_0": [0, 1, 0]]
        let result = matcher.match(embeddings: embeddings)
        XCTAssertEqual(result["SPEAKER_0"], "SPEAKER_0")
    }

    // MARK: - Save/Load

    func testSaveAndLoadDB() {
        let matcher = SpeakerMatcher(dbPath: dbPath)
        let speakers = [
            StoredSpeaker(name: "Roman", embedding: [1, 0, 0]),
            StoredSpeaker(name: "Anna", embedding: [0, 1, 0]),
        ]
        matcher.saveDB(speakers)

        let loaded = matcher.loadDB()
        XCTAssertEqual(loaded.count, 2)
        XCTAssertEqual(loaded[0].name, "Roman")
        XCTAssertEqual(loaded[1].name, "Anna")
    }

    func testLoadDBMissing() {
        let matcher = SpeakerMatcher(dbPath: dbPath)
        let loaded = matcher.loadDB()
        XCTAssertTrue(loaded.isEmpty)
    }

    // MARK: - Update DB

    func testUpdateDBAddsNewSpeaker() {
        let matcher = SpeakerMatcher(dbPath: dbPath)
        let stored = [StoredSpeaker(name: "Roman", embedding: [1, 0, 0])]
        matcher.saveDB(stored)

        matcher.updateDB(
            mapping: ["SPEAKER_0": "Roman", "SPEAKER_1": "Anna"],
            embeddings: ["SPEAKER_0": [1, 0, 0], "SPEAKER_1": [0, 1, 0]]
        )

        let loaded = matcher.loadDB()
        XCTAssertEqual(loaded.count, 2)
        let names = Set(loaded.map(\.name))
        XCTAssertTrue(names.contains("Roman"))
        XCTAssertTrue(names.contains("Anna"))
    }

    func testUpdateDBSkipsUnnamedSpeakers() {
        let matcher = SpeakerMatcher(dbPath: dbPath)
        matcher.updateDB(
            mapping: ["SPEAKER_0": "Roman", "SPEAKER_1": "SPEAKER_1"],
            embeddings: ["SPEAKER_0": [1, 0, 0], "SPEAKER_1": [0, 1, 0]]
        )
        let loaded = matcher.loadDB()
        // SPEAKER_1 was not named by user, should not be saved
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded[0].name, "Roman")
    }
}
```

**Step 2: Run tests to verify they fail**

Run: `cd app/MeetingTranscriber && swift test --filter SpeakerMatcherTests 2>&1 | tail -3`
Expected: Compilation error — `SpeakerMatcher` not defined

**Step 3: Implement SpeakerMatcher**

```swift
import Foundation

struct StoredSpeaker: Codable {
    let name: String
    let embedding: [Float]
}

class SpeakerMatcher {
    private let dbPath: URL
    private let threshold: Float

    init(dbPath: URL? = nil, threshold: Float = 0.65) {
        self.dbPath = dbPath ?? AppPaths.speakersDB
        self.threshold = threshold
    }

    /// Match diarization embeddings against stored speakers.
    /// Returns mapping: { "SPEAKER_0": "Roman", "SPEAKER_1": "SPEAKER_1" }
    func match(embeddings: [String: [Float]]) -> [String: String] {
        let stored = loadDB()
        var mapping: [String: String] = [:]
        var usedNames: Set<String> = []

        // Sort by label for deterministic assignment
        let sorted = embeddings.sorted { $0.key < $1.key }

        for (label, embedding) in sorted {
            var bestName: String?
            var bestDistance: Float = Float.greatestFiniteMagnitude

            for speaker in stored where !usedNames.contains(speaker.name) {
                let dist = Self.cosineDistance(embedding, speaker.embedding)
                if dist < bestDistance && dist < threshold {
                    bestDistance = dist
                    bestName = speaker.name
                }
            }

            if let name = bestName {
                mapping[label] = name
                usedNames.insert(name)
            } else {
                mapping[label] = label
            }
        }

        return mapping
    }

    /// Update speaker DB with confirmed names and their embeddings.
    func updateDB(mapping: [String: String], embeddings: [String: [Float]]) {
        var stored = loadDB()

        for (label, name) in mapping {
            // Skip if user didn't name this speaker (label == name)
            guard name != label, let embedding = embeddings[label] else { continue }

            // Update existing or add new
            if let idx = stored.firstIndex(where: { $0.name == name }) {
                stored[idx] = StoredSpeaker(name: name, embedding: embedding)
            } else {
                stored.append(StoredSpeaker(name: name, embedding: embedding))
            }
        }

        saveDB(stored)
    }

    func loadDB() -> [StoredSpeaker] {
        guard let data = try? Data(contentsOf: dbPath) else { return [] }
        return (try? JSONDecoder().decode([StoredSpeaker].self, from: data)) ?? []
    }

    func saveDB(_ speakers: [StoredSpeaker]) {
        guard let data = try? JSONEncoder().encode(speakers) else { return }
        let tmp = dbPath.deletingLastPathComponent()
            .appendingPathComponent("speakers.json.tmp")
        try? data.write(to: tmp, options: .atomic)
        try? FileManager.default.replaceItemAt(dbPath, withItemAt: tmp)
    }

    /// Cosine distance: 0 = identical, 2 = opposite.
    static func cosineDistance(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count, !a.isEmpty else { return 2 }
        var dot: Float = 0
        var normA: Float = 0
        var normB: Float = 0
        for i in 0..<a.count {
            dot += a[i] * b[i]
            normA += a[i] * a[i]
            normB += b[i] * b[i]
        }
        let denom = sqrt(normA) * sqrt(normB)
        guard denom > 0 else { return 2 }
        return 1 - dot / denom
    }
}
```

**Step 4: Run tests to verify they pass**

Run: `cd app/MeetingTranscriber && swift test --filter SpeakerMatcherTests`
Expected: All tests pass

**Step 5: Commit**

```bash
git add app/MeetingTranscriber/Sources/SpeakerMatcher.swift app/MeetingTranscriber/Tests/SpeakerMatcherTests.swift
git commit -m "feat(app): add SpeakerMatcher for native speaker recognition"
```

---

### Task 3: Create FluidDiarizer (DiarizationProvider implementation)

**Files:**
- Create: `app/MeetingTranscriber/Sources/FluidDiarizer.swift`
- Create: `app/MeetingTranscriber/Tests/FluidDiarizerTests.swift`

**Context:** `DiarizationProvider` protocol is defined in `Sources/DiarizationProcess.swift:20-22`. `DiarizationResult` struct is at lines 7-17. Both must stay unchanged so existing code (PipelineQueue, assignSpeakers) keeps working.

**Step 1: Add embeddings field to DiarizationResult**

In `Sources/DiarizationProcess.swift`, add an optional `embeddings` field:

```swift
struct DiarizationResult {
    struct Segment {
        let start: TimeInterval
        let end: TimeInterval
        let speaker: String
    }

    let segments: [Segment]
    let speakingTimes: [String: TimeInterval]
    let autoNames: [String: String]
    var embeddings: [String: [Float]]?  // NEW: per-speaker averaged embeddings
}
```

Update all existing `DiarizationResult(...)` call sites to include `embeddings: nil`:
- `DiarizationProcess.parseOutput()` at line 178
- Any test mocks that create `DiarizationResult`

**Step 2: Write FluidDiarizer tests**

```swift
import XCTest
@testable import MeetingTranscriber

final class FluidDiarizerTests: XCTestCase {

    func testIsAlwaysAvailable() {
        let diarizer = FluidDiarizer()
        XCTAssertTrue(diarizer.isAvailable)
    }

    func testRunWithTestFixture() async throws {
        // This test requires the two_speakers_de.wav fixture
        // Skip if not available (CI without fixtures)
        let fixturePath = Bundle.module.url(forResource: "two_speakers_de", withExtension: "wav")
            ?? URL(fileURLWithPath: "Tests/fixtures/two_speakers_de.wav")
        guard FileManager.default.fileExists(atPath: fixturePath.path) else {
            throw XCTSkip("Test fixture not available")
        }

        let diarizer = FluidDiarizer()
        let result = try await diarizer.run(
            audioPath: fixturePath,
            numSpeakers: 2,
            meetingTitle: "Test"
        )

        XCTAssertFalse(result.segments.isEmpty, "Should detect segments")
        XCTAssertFalse(result.speakingTimes.isEmpty, "Should compute speaking times")
        XCTAssertNotNil(result.embeddings, "Should return embeddings")
    }
}
```

**Step 3: Implement FluidDiarizer**

```swift
import FluidAudio
import Foundation
import os.log

private let logger = Logger(subsystem: AppPaths.logSubsystem, category: "FluidDiarizer")

class FluidDiarizer: DiarizationProvider {
    private var manager: OfflineDiarizerManager?

    var isAvailable: Bool { true }

    func run(audioPath: URL, numSpeakers: Int?, meetingTitle: String) async throws -> DiarizationResult {
        var config = OfflineDiarizerConfig()
        if let n = numSpeakers, n > 0 {
            config = config.withSpeakers(exactly: n)
        }

        if manager == nil {
            manager = OfflineDiarizerManager(config: config)
            try await manager!.prepareModels()
            logger.info("FluidAudio models ready")
        }

        logger.info("Starting diarization: \(audioPath.lastPathComponent)")
        let fluidResult = try await manager!.process(audioPath)

        // Convert FluidAudio segments to our DiarizationResult
        let segments = fluidResult.segments.map { seg in
            DiarizationResult.Segment(
                start: TimeInterval(seg.startTimeSeconds),
                end: TimeInterval(seg.endTimeSeconds),
                speaker: "SPEAKER_\(seg.speakerId)"
            )
        }

        // Compute speaking times
        var speakingTimes: [String: TimeInterval] = [:]
        for seg in segments {
            speakingTimes[seg.speaker, default: 0] += seg.end - seg.start
        }

        // Convert speaker database embeddings
        var embeddings: [String: [Float]]?
        if let db = fluidResult.speakerDatabase {
            embeddings = [:]
            for (id, emb) in db {
                embeddings!["SPEAKER_\(id)"] = emb
            }
        }

        logger.info("Diarization complete: \(segments.count) segments, \(speakingTimes.count) speakers")

        return DiarizationResult(
            segments: segments,
            speakingTimes: speakingTimes,
            autoNames: [:],
            embeddings: embeddings
        )
    }
}
```

**Step 4: Run tests**

Run: `cd app/MeetingTranscriber && swift test --filter FluidDiarizerTests`
Expected: `testIsAlwaysAvailable` passes, `testRunWithTestFixture` may skip if no fixture

**Step 5: Commit**

```bash
git add app/MeetingTranscriber/Sources/FluidDiarizer.swift app/MeetingTranscriber/Sources/DiarizationProcess.swift app/MeetingTranscriber/Tests/FluidDiarizerTests.swift
git commit -m "feat(app): add FluidDiarizer with CoreML-based diarization"
```

---

### Task 4: Wire FluidDiarizer + SpeakerMatcher into PipelineQueue

**Files:**
- Modify: `app/MeetingTranscriber/Sources/PipelineQueue.swift:186-232` (diarization section)
- Modify: `app/MeetingTranscriber/Sources/MeetingTranscriberApp.swift` (factory + callbacks)

**Context:** Currently `PipelineQueue.processNext()` at line 188 does `if diarizeEnabled, let diarizationFactory { ... }`. The diarization block runs the provider, then assigns speakers. We need to add speaker matching and popup triggering between diarization and speaker assignment.

**Step 1: Add speaker naming continuation to PipelineQueue**

Add these properties to `PipelineQueue`:

```swift
/// Pending speaker naming request — set when diarization finds unmatched speakers.
/// The popup reads this and calls `completeSpeakerNaming()` with the user's mapping.
var pendingSpeakerNaming: SpeakerNamingData?

struct SpeakerNamingData {
    let jobID: UUID
    let meetingTitle: String
    let mapping: [String: String]
    let speakingTimes: [String: TimeInterval]
    let embeddings: [String: [Float]]
}

/// Continuation for suspending pipeline while user names speakers.
private var speakerNamingContinuation: CheckedContinuation<[String: String], Never>?

/// Called by the naming popup when user confirms.
func completeSpeakerNaming(mapping: [String: String]) {
    pendingSpeakerNaming = nil
    speakerNamingContinuation?.resume(returning: mapping)
    speakerNamingContinuation = nil
}
```

**Step 2: Update diarization section in processNext()**

Replace the diarization block (lines 186-232) with:

```swift
// --- Diarization (optional) ---
var finalTranscript = transcript
if diarizeEnabled, let diarizationFactory {
    let diarizeProcess = diarizationFactory()
    if diarizeProcess.isAvailable {
        updateJobState(id: jobID, to: .diarizing)

        let mix16k = workDir.appendingPathComponent("mix_16k.wav")
        if !FileManager.default.fileExists(atPath: mix16k.path) {
            try AudioMixer.resampleFile(from: mixPath, to: mix16k)
        }

        do {
            let diarization = try await diarizeProcess.run(
                audioPath: mix16k,
                numSpeakers: nil,
                meetingTitle: title
            )

            // Speaker matching
            var autoNames = diarization.autoNames
            if let embeddings = diarization.embeddings {
                let matcher = SpeakerMatcher()
                let matched = matcher.match(embeddings: embeddings)
                autoNames = matched.filter { $0.value != $0.key }

                // Check if any speakers are unmatched
                let unmatched = matched.filter { $0.value == $0.key }
                if !unmatched.isEmpty {
                    // Show naming popup and suspend until user responds
                    let userMapping = await withCheckedContinuation { continuation in
                        self.speakerNamingContinuation = continuation
                        self.pendingSpeakerNaming = SpeakerNamingData(
                            jobID: jobID,
                            meetingTitle: title,
                            mapping: matched,
                            speakingTimes: diarization.speakingTimes,
                            embeddings: embeddings
                        )
                        NotificationCenter.default.post(name: .showSpeakerNaming, object: nil)
                    }

                    // Merge user names into mapping
                    for (label, name) in userMapping where !name.isEmpty {
                        autoNames[label] = name
                    }

                    // Save to DB
                    matcher.updateDB(mapping: autoNames.merging(matched) { user, _ in user },
                                     embeddings: embeddings)
                } else {
                    // All matched — update DB with fresh embeddings
                    matcher.updateDB(mapping: matched, embeddings: embeddings)
                }
            }

            // Apply speaker names to segments
            let namedDiarization = DiarizationResult(
                segments: diarization.segments,
                speakingTimes: diarization.speakingTimes,
                autoNames: autoNames,
                embeddings: diarization.embeddings
            )

            let segments: [TimestampedSegment]
            if let cached = cachedSegments {
                segments = cached
            } else {
                let segmentAudioPath = appPath != nil
                    ? workDir.appendingPathComponent("app_16k.wav")
                    : mix16k
                segments = try await whisperKit.transcribeSegments(audioPath: segmentAudioPath)
            }

            let labeled = DiarizationProcess.assignSpeakers(
                transcript: segments,
                diarization: namedDiarization
            )
            finalTranscript = labeled.map(\.formattedLine).joined(separator: "\n")
            logger.info("Diarization complete: \(namedDiarization.segments.count) segments")
        } catch {
            logger.warning("Diarization failed, using undiarized transcript: \(error.localizedDescription)")
        }
    }
}
```

**Step 3: Update MeetingTranscriberApp — replace IPC with direct popup**

In `MeetingTranscriberApp.swift`:

1. Remove `private let ipc = IPCManager()` and `private let ipcPoller = IPCPoller()`
2. Change `@State private var speakerRequest: SpeakerRequest?` to observe `pipelineQueue.pendingSpeakerNaming`
3. Update `configurePipelineCallbacks()` — remove IPC poller start/stop
4. Update speaker-naming Window to use `SpeakerNamingData` instead of `SpeakerRequest`
5. Update `makePipelineQueue()` to use `FluidDiarizer`:

```swift
private func makePipelineQueue() -> PipelineQueue {
    PipelineQueue(
        whisperKit: whisperKit,
        diarizationFactory: { FluidDiarizer() },
        protocolGenerator: DefaultProtocolGenerator(),
        outputDir: WatchLoop.defaultOutputDir,
        diarizeEnabled: settings.diarize,
        micLabel: settings.micName
    )
}
```

Update `configurePipelineCallbacks()`:

```swift
private func configurePipelineCallbacks() {
    pipelineQueue.onJobStateChange = { [notifications] job, _, newState in
        switch newState {
        case .done:
            notifications.notify(title: "Protocol Ready", body: job.meetingTitle)
        case .error:
            if let err = job.error {
                notifications.notify(title: "Error", body: err)
            }
        default:
            break
        }
    }
}
```

**Step 4: Adapt SpeakerNamingView to work with SpeakerNamingData**

The `SpeakerNamingView` currently takes a `SpeakerRequest`. Adapt it to accept `SpeakerNamingData` from PipelineQueue. The key changes:
- Input: `SpeakerNamingData` instead of `SpeakerRequest`
- Speaker list: derived from `mapping` + `speakingTimes`
- No audio sample playback (FluidAudio doesn't export audio clips — remove play button)
- On confirm: call `pipelineQueue.completeSpeakerNaming(mapping:)`

Create a new `SpeakerNamingInfo` struct to bridge:

```swift
struct SpeakerNamingInfo: Identifiable {
    let label: String
    let autoName: String?
    let speakingTimeSeconds: Double
    var id: String { label }
}
```

**Step 5: Run full test suite**

Run: `cd app/MeetingTranscriber && swift test 2>&1 | tail -5`
Expected: All tests pass (some IPC tests may need updating — see Task 6)

**Step 6: Commit**

```bash
git add app/MeetingTranscriber/Sources/PipelineQueue.swift app/MeetingTranscriber/Sources/MeetingTranscriberApp.swift app/MeetingTranscriber/Sources/SpeakerNamingView.swift
git commit -m "feat(app): wire FluidDiarizer + SpeakerMatcher into pipeline"
```

---

### Task 5: Remove HF token from Settings UI

**Files:**
- Modify: `app/MeetingTranscriber/Sources/SettingsView.swift`
- Modify: `app/MeetingTranscriber/Sources/AppSettings.swift`
- Modify: `app/MeetingTranscriber/Tests/SettingsViewTests.swift`
- Modify: `app/MeetingTranscriber/Tests/AppSettingsTests.swift`

**Step 1: Remove HF token UI from SettingsView**

In `SettingsView.swift`, remove the entire HF token section (lines 138-168) inside the `if settings.diarize { }` block. Keep the "Expected Speakers" stepper.

Remove `@State private var hasToken = false` and `hasToken = settings.hasHFToken` from `onAppear`.

Remove the `tokenStatusInfo()` free function.

Reduce the window height since the token section is gone:
```swift
.frame(width: 420, height: settings.diarize ? 560 : (settings.noMic ? 490 : 590))
```

**Step 2: Remove HF token properties from AppSettings**

In `AppSettings.swift`, remove:
- `var hasHFToken: Bool` (line 78-80)
- `var hfToken: String?` (line 83-85)
- `func setHFToken(_ token: String)` (lines 89-96)

**Step 3: Update tests**

In `SettingsViewTests.swift`, remove:
- `testDiarizeEnabledShowsTokenSection`
- `testDiarizeEnabledShowsClearButton`
- `testDiarizeEnabledShowsGetTokenLink`
- `testDiarizeDisabledHidesTokenSection`

In `AppSettingsTests.swift`, remove any HF token assertions.

**Step 4: Run tests**

Run: `cd app/MeetingTranscriber && swift test --filter SettingsViewTests && swift test --filter AppSettingsTests`
Expected: All remaining tests pass

**Step 5: Commit**

```bash
git add app/MeetingTranscriber/Sources/SettingsView.swift app/MeetingTranscriber/Sources/AppSettings.swift app/MeetingTranscriber/Tests/SettingsViewTests.swift app/MeetingTranscriber/Tests/AppSettingsTests.swift
git commit -m "refactor(app): remove HuggingFace token UI (no longer needed)"
```

---

### Task 6: Remove Python diarization code and IPC infrastructure

**Files:**
- Delete: `app/MeetingTranscriber/Sources/IPCPoller.swift`
- Delete: `app/MeetingTranscriber/Sources/IPCManager.swift`
- Delete: `app/MeetingTranscriber/Sources/SpeakerRequest.swift`
- Delete: `app/MeetingTranscriber/Tests/IPCPollerTests.swift`
- Delete: `app/MeetingTranscriber/Tests/IPCManagerTests.swift`
- Delete: `app/MeetingTranscriber/Tests/SpeakerIPCTests.swift`
- Modify: `app/MeetingTranscriber/Sources/DiarizationProcess.swift` — keep only `assignSpeakers()`, `DiarizationResult`, `DiarizationProvider`, `DiarizationError`
- Delete: `tools/diarize/diarize.py`
- Delete: `tools/diarize/requirements.txt`

**Step 1: Remove IPC files**

Delete `IPCPoller.swift`, `IPCManager.swift`, `SpeakerRequest.swift` and their test files. Fix any remaining references in other files (search for `IPCPoller`, `IPCManager`, `SpeakerRequest`, `SpeakerCountRequest`).

Note: `SpeakerCountView` uses `SpeakerCountRequest` — either remove the count view too (FluidAudio handles speaker count via config), or keep a simplified version without IPC.

**Step 2: Trim DiarizationProcess.swift**

Keep only:
- `DiarizationResult` struct (with new `embeddings` field)
- `DiarizationProvider` protocol
- `DiarizationProcess.assignSpeakers()` static method
- `DiarizationError` enum

Remove the entire `DiarizationProcess` class (subprocess logic). Move `assignSpeakers()` to a free function or keep the class shell with just the static method.

**Step 3: Remove Python diarize files**

```bash
rm tools/diarize/diarize.py tools/diarize/requirements.txt
rmdir tools/diarize 2>/dev/null || true
```

**Step 4: Run full test suite**

Run: `cd app/MeetingTranscriber && swift test 2>&1 | tail -5`
Expected: All tests pass. Some tests may need fixing if they reference removed types.

**Step 5: Commit**

```bash
git add -A
git commit -m "refactor(app): remove Python diarization and IPC infrastructure

FluidAudio provides native CoreML diarization. The Python subprocess,
IPC file polling, and HuggingFace token are no longer needed."
```

---

### Task 7: Update build_release.sh — remove Python diarization step

**Files:**
- Modify: `scripts/build_release.sh`
- Modify: `.github/workflows/release.yml`

**Step 1: Remove Step 4 (Python diarize venv) from build_release.sh**

Remove the entire `WITH_DIARIZE` variable and Step 4 block (lines 43, 47-48, 106-163). Remove `--no-diarize` flag handling. Remove Python-related codesigning (lines 200-205). Remove `CACHE_DIR` variable.

The build script should go directly from Step 3 (assemble bundle) to Step 5 (code signing).

**Step 2: Update release.yml**

Remove `--no-diarize` from the else branch:
```yaml
run: |
  if [ -n "$DEVELOPER_ID" ]; then
    ./scripts/build_release.sh
  else
    ./scripts/build_release.sh --no-notarize
  fi
```

**Step 3: Verify build script runs**

Run: `./scripts/build_release.sh --no-notarize`
Expected: Build succeeds, bundle is ~6 MB (models download on first app launch)

**Step 4: Commit**

```bash
git add scripts/build_release.sh .github/workflows/release.yml
git commit -m "build: remove Python diarization from release build

Bundle no longer includes python-diarize venv (~700 MB savings).
Diarization models (~254 MB) are downloaded on first app launch."
```

---

### Task 8: Reset speakers.json on first FluidAudio run

**Files:**
- Modify: `app/MeetingTranscriber/Sources/SpeakerMatcher.swift`

**Step 1: Add migration logic**

Add a static method to detect and reset old-format speakers.json:

```swift
/// Reset old pyannote-format speakers.json (incompatible embeddings).
/// The old format was: { "name": [[float]] } dict.
/// The new format is: [{ "name": str, "embedding": [float] }] array.
static func migrateIfNeeded(dbPath: URL) {
    guard let data = try? Data(contentsOf: dbPath),
          let json = try? JSONSerialization.jsonObject(with: data) else { return }

    // Old format is a dictionary, new format is an array
    if json is [String: Any] {
        // Back up and reset
        let backup = dbPath.deletingLastPathComponent()
            .appendingPathComponent("speakers.json.bak")
        try? FileManager.default.moveItem(at: dbPath, to: backup)
    }
}
```

Call this in `SpeakerMatcher.init()`.

**Step 2: Write test**

```swift
func testMigrateOldFormatResetsDB() {
    // Write old dict format
    let oldData = try! JSONSerialization.data(withJSONObject: [
        "Roman": [[1.0, 0.0, 0.0]],
    ])
    try! oldData.write(to: dbPath)

    SpeakerMatcher.migrateIfNeeded(dbPath: dbPath)

    // Old file should be gone (backed up)
    XCTAssertFalse(FileManager.default.fileExists(atPath: dbPath.path))
    let backup = dbPath.deletingLastPathComponent()
        .appendingPathComponent("speakers.json.bak")
    XCTAssertTrue(FileManager.default.fileExists(atPath: backup.path))
}

func testMigrateNewFormatKeepsDB() {
    let matcher = SpeakerMatcher(dbPath: dbPath)
    matcher.saveDB([StoredSpeaker(name: "Roman", embedding: [1, 0, 0])])

    SpeakerMatcher.migrateIfNeeded(dbPath: dbPath)

    // Should still exist
    XCTAssertTrue(FileManager.default.fileExists(atPath: dbPath.path))
}
```

**Step 3: Run tests**

Run: `cd app/MeetingTranscriber && swift test --filter SpeakerMatcherTests`
Expected: All pass

**Step 4: Commit**

```bash
git add app/MeetingTranscriber/Sources/SpeakerMatcher.swift app/MeetingTranscriber/Tests/SpeakerMatcherTests.swift
git commit -m "feat(app): auto-migrate old speakers.json format on first run"
```

---

### Task 9: Full integration test + cleanup

**Files:**
- Modify: `app/MeetingTranscriber/Tests/WatchLoopE2ETests.swift`
- Modify: `CLAUDE.md` (update architecture docs)

**Step 1: Update E2E tests**

Update `WatchLoopE2ETests.testDiarizationSkippedWhenNotAvailable` — `FluidDiarizer.isAvailable` is always true, so this test needs a different mock (e.g., a mock that throws).

Update `testFullPipelineWithRealDiarization` to use FluidDiarizer instead of DiarizationProcess.

**Step 2: Run full test suite**

Run: `cd app/MeetingTranscriber && swift test`
Expected: All 340+ tests pass (minus removed IPC tests, plus new SpeakerMatcher/FluidDiarizer tests)

**Step 3: Update CLAUDE.md**

Update the project structure, pipeline description, and architecture notes to reflect:
- FluidAudio replaces pyannote
- No Python diarization
- No IPC for speaker naming
- No HF token needed
- Remove `tools/diarize/` from structure
- Remove `IPCPoller`, `IPCManager`, `SpeakerRequest` from Sources list
- Add `FluidDiarizer`, `SpeakerMatcher` to Sources list

**Step 4: Commit**

```bash
git add app/MeetingTranscriber/Tests/ CLAUDE.md
git commit -m "test(app): update E2E tests and docs for native diarization"
```

---

### Task 10: Build release and verify

**Step 1: Build release DMG**

Run: `./scripts/build_release.sh --no-notarize`
Expected: Bundle is ~6 MB (no Python), builds successfully

**Step 2: Launch and test**

```bash
open .build/release/MeetingTranscriber.app
```

- Verify models download on first launch (~254 MB)
- Settings should not show HF token section
- Start a test meeting → verify diarization runs
- Verify speaker naming popup appears for unknown speakers

**Step 3: Push**

```bash
git push origin main
```
