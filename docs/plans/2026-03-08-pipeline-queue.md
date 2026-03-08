# Pipeline Queue Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Decouple recording from post-processing so a new meeting can be detected immediately after recording ends, while transcription/diarization/protocol generation runs in a background queue.

**Architecture:** Split `WatchLoop` into two components: `WatchLoop` (detection + recording only) and `PipelineQueue` (transcription + diarization + protocol). WatchLoop enqueues a `PipelineJob` after recording stops and immediately returns to watching. PipelineQueue processes one job at a time, with transcription and diarization running in parallel via `async let`. Every state change writes a JSON snapshot and appends to a JSONL log for debugging.

**Tech Stack:** Swift, SwiftUI, @Observable, @MainActor, async/await, JSONEncoder

---

### Task 1: PipelineJob Model

**Files:**
- Create: `app/MeetingTranscriber/Sources/PipelineJob.swift`
- Test: `app/MeetingTranscriber/Tests/PipelineJobTests.swift`

**Step 1: Write the tests**

```swift
import XCTest
@testable import MeetingTranscriber

final class PipelineJobTests: XCTestCase {

    func testInitialStateIsWaiting() {
        let job = PipelineJob(
            meetingTitle: "Standup",
            appName: "Microsoft Teams",
            mixPath: URL(fileURLWithPath: "/tmp/mix.wav"),
            appPath: nil,
            micPath: nil,
            micDelay: 0
        )
        XCTAssertEqual(job.state, .waiting)
        XCTAssertNil(job.error)
        XCTAssertNotNil(job.id)
    }

    func testJobIsCodable() throws {
        let job = PipelineJob(
            meetingTitle: "Sprint",
            appName: "Zoom",
            mixPath: URL(fileURLWithPath: "/tmp/mix.wav"),
            appPath: URL(fileURLWithPath: "/tmp/app.wav"),
            micPath: URL(fileURLWithPath: "/tmp/mic.wav"),
            micDelay: 0.5
        )
        let data = try JSONEncoder().encode(job)
        let decoded = try JSONDecoder().decode(PipelineJob.self, from: data)
        XCTAssertEqual(decoded.id, job.id)
        XCTAssertEqual(decoded.meetingTitle, "Sprint")
        XCTAssertEqual(decoded.state, .waiting)
        XCTAssertEqual(decoded.micDelay, 0.5)
    }

    func testJobStateIsCodable() throws {
        for state in [JobState.waiting, .transcribing, .diarizing,
                      .generatingProtocol, .done, .error] {
            let data = try JSONEncoder().encode(state)
            let decoded = try JSONDecoder().decode(JobState.self, from: data)
            XCTAssertEqual(decoded, state)
        }
    }

    func testJobStateRawValues() {
        XCTAssertEqual(JobState.waiting.rawValue, "waiting")
        XCTAssertEqual(JobState.transcribing.rawValue, "transcribing")
        XCTAssertEqual(JobState.diarizing.rawValue, "diarizing")
        XCTAssertEqual(JobState.generatingProtocol.rawValue, "generatingProtocol")
        XCTAssertEqual(JobState.done.rawValue, "done")
        XCTAssertEqual(JobState.error.rawValue, "error")
    }
}
```

**Step 2: Run tests to verify they fail**

Run: `cd app/MeetingTranscriber && swift test --filter PipelineJobTests 2>&1 | tail -5`
Expected: FAIL — `PipelineJob` not found

**Step 3: Write the implementation**

```swift
import Foundation

enum JobState: String, Codable, Sendable {
    case waiting
    case transcribing
    case diarizing
    case generatingProtocol
    case done
    case error
}

struct PipelineJob: Identifiable, Codable, Sendable {
    let id: UUID
    let meetingTitle: String
    let appName: String
    let mixPath: URL
    let appPath: URL?
    let micPath: URL?
    let micDelay: TimeInterval
    let enqueuedAt: Date
    var state: JobState
    var error: String?
    var protocolPath: URL?

    init(
        meetingTitle: String,
        appName: String,
        mixPath: URL,
        appPath: URL?,
        micPath: URL?,
        micDelay: TimeInterval
    ) {
        self.id = UUID()
        self.meetingTitle = meetingTitle
        self.appName = appName
        self.mixPath = mixPath
        self.appPath = appPath
        self.micPath = micPath
        self.micDelay = micDelay
        self.enqueuedAt = Date()
        self.state = .waiting
        self.error = nil
        self.protocolPath = nil
    }
}
```

**Step 4: Run tests to verify they pass**

Run: `cd app/MeetingTranscriber && swift test --filter PipelineJobTests 2>&1 | tail -5`
Expected: PASS — all 4 tests

**Step 5: Commit**

```bash
git add app/MeetingTranscriber/Sources/PipelineJob.swift app/MeetingTranscriber/Tests/PipelineJobTests.swift
git commit -m "feat(app): add PipelineJob model and JobState enum"
```

---

### Task 2: PipelineQueue Skeleton (Enqueue + JSON Logging)

**Files:**
- Create: `app/MeetingTranscriber/Sources/PipelineQueue.swift`
- Test: `app/MeetingTranscriber/Tests/PipelineQueueTests.swift`

**Context:** PipelineQueue is `@MainActor @Observable` so SwiftUI can observe it. It manages a `[PipelineJob]` array. On every state change it writes two files:
- `~/.meeting-transcriber/pipeline_queue.json` — atomic overwrite (current snapshot)
- `~/.meeting-transcriber/pipeline_log.jsonl` — append one JSON line per event

This task builds only the skeleton: enqueue, state transitions, logging. Processing logic comes in Task 3.

**Step 1: Write the tests**

```swift
import XCTest
@testable import MeetingTranscriber

@MainActor
final class PipelineQueueTests: XCTestCase {

    private var tmpDir: URL!
    private var queue: PipelineQueue!

    override func setUp() async throws {
        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("pipeline_queue_test_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        queue = PipelineQueue(logDir: tmpDir)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tmpDir)
    }

    private func makeJob(title: String = "Test Meeting") -> PipelineJob {
        PipelineJob(
            meetingTitle: title,
            appName: "Microsoft Teams",
            mixPath: URL(fileURLWithPath: "/tmp/mix.wav"),
            appPath: nil,
            micPath: nil,
            micDelay: 0
        )
    }

    func testEnqueueAddsJob() {
        let job = makeJob()
        queue.enqueue(job)
        XCTAssertEqual(queue.jobs.count, 1)
        XCTAssertEqual(queue.jobs[0].meetingTitle, "Test Meeting")
    }

    func testEnqueueMultipleJobs() {
        queue.enqueue(makeJob(title: "Meeting 1"))
        queue.enqueue(makeJob(title: "Meeting 2"))
        XCTAssertEqual(queue.jobs.count, 2)
    }

    func testSnapshotWrittenOnEnqueue() {
        queue.enqueue(makeJob())
        let snapshotPath = tmpDir.appendingPathComponent("pipeline_queue.json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: snapshotPath.path))
    }

    func testSnapshotIsValidJSON() throws {
        queue.enqueue(makeJob(title: "Standup"))
        let snapshotPath = tmpDir.appendingPathComponent("pipeline_queue.json")
        let data = try Data(contentsOf: snapshotPath)
        let jobs = try JSONDecoder().decode([PipelineJob].self, from: data)
        XCTAssertEqual(jobs.count, 1)
        XCTAssertEqual(jobs[0].meetingTitle, "Standup")
    }

    func testLogAppendedOnEnqueue() throws {
        queue.enqueue(makeJob())
        let logPath = tmpDir.appendingPathComponent("pipeline_log.jsonl")
        XCTAssertTrue(FileManager.default.fileExists(atPath: logPath.path))
        let content = try String(contentsOf: logPath, encoding: .utf8)
        XCTAssertTrue(content.contains("enqueued"))
    }

    func testActiveJobs() {
        var job1 = makeJob(title: "Active")
        job1.state = .transcribing
        queue.enqueue(job1)
        queue.enqueue(makeJob(title: "Waiting"))
        XCTAssertEqual(queue.activeJobs.count, 1)
        XCTAssertEqual(queue.activeJobs[0].meetingTitle, "Active")
    }

    func testPendingJobs() {
        queue.enqueue(makeJob(title: "Waiting 1"))
        queue.enqueue(makeJob(title: "Waiting 2"))
        XCTAssertEqual(queue.pendingJobs.count, 2)
    }

    func testRemoveCompletedJob() {
        var job = makeJob()
        job.state = .done
        queue.enqueue(job)
        XCTAssertEqual(queue.jobs.count, 1)
        queue.removeJob(id: job.id)
        XCTAssertEqual(queue.jobs.count, 0)
    }
}
```

**Step 2: Run tests to verify they fail**

Run: `cd app/MeetingTranscriber && swift test --filter PipelineQueueTests 2>&1 | tail -5`
Expected: FAIL — `PipelineQueue` not found

**Step 3: Write the implementation**

```swift
import Foundation
import os.log

private let logger = Logger(subsystem: "com.meetingtranscriber", category: "PipelineQueue")

@MainActor
@Observable
class PipelineQueue {
    private(set) var jobs: [PipelineJob] = []
    private let logDir: URL

    /// Called when a job completes (success or error) — for notifications
    var onJobStateChange: ((PipelineJob, JobState, JobState) -> Void)?

    init(logDir: URL? = nil) {
        self.logDir = logDir ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".meeting-transcriber")
    }

    var activeJobs: [PipelineJob] {
        jobs.filter { [.transcribing, .diarizing, .generatingProtocol].contains($0.state) }
    }

    var pendingJobs: [PipelineJob] {
        jobs.filter { $0.state == .waiting }
    }

    var completedJobs: [PipelineJob] {
        jobs.filter { $0.state == .done }
    }

    var errorJobs: [PipelineJob] {
        jobs.filter { $0.state == .error }
    }

    func enqueue(_ job: PipelineJob) {
        jobs.append(job)
        appendLog(jobID: job.id, event: "enqueued", from: nil, to: job.state)
        writeSnapshot()
        logger.info("Enqueued job: \(job.meetingTitle) (\(job.id))")
    }

    func removeJob(id: UUID) {
        jobs.removeAll { $0.id == id }
        writeSnapshot()
    }

    func updateJobState(id: UUID, to newState: JobState, error: String? = nil) {
        guard let index = jobs.firstIndex(where: { $0.id == id }) else { return }
        let oldState = jobs[index].state
        jobs[index].state = newState
        if let error { jobs[index].error = error }
        appendLog(jobID: id, event: "state_change", from: oldState, to: newState)
        writeSnapshot()
        onJobStateChange?(jobs[index], oldState, newState)
    }

    // MARK: - JSON Logging

    private func writeSnapshot() {
        do {
            try FileManager.default.createDirectory(at: logDir, withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(jobs)
            let tmpPath = logDir.appendingPathComponent("pipeline_queue.tmp")
            try data.write(to: tmpPath)
            let snapshotPath = logDir.appendingPathComponent("pipeline_queue.json")
            _ = try FileManager.default.replaceItemAt(snapshotPath, withItemAt: tmpPath)
        } catch {
            logger.error("Failed to write queue snapshot: \(error)")
        }
    }

    private func appendLog(jobID: UUID, event: String, from: JobState?, to: JobState) {
        let entry: [String: String] = [
            "timestamp": ISO8601DateFormatter().string(from: Date()),
            "job_id": jobID.uuidString,
            "event": event,
            "from": from?.rawValue ?? "-",
            "to": to.rawValue,
        ]
        do {
            try FileManager.default.createDirectory(at: logDir, withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(entry)
            let logPath = logDir.appendingPathComponent("pipeline_log.jsonl")
            let line = String(data: data, encoding: .utf8)! + "\n"
            if FileManager.default.fileExists(atPath: logPath.path) {
                let handle = try FileHandle(forWritingTo: logPath)
                handle.seekToEndOfFile()
                handle.write(line.data(using: .utf8)!)
                handle.closeFile()
            } else {
                try line.write(to: logPath, atomically: true, encoding: .utf8)
            }
        } catch {
            logger.error("Failed to append pipeline log: \(error)")
        }
    }
}
```

**Step 4: Run tests to verify they pass**

Run: `cd app/MeetingTranscriber && swift test --filter PipelineQueueTests 2>&1 | tail -5`
Expected: PASS — all 9 tests

**Step 5: Commit**

```bash
git add app/MeetingTranscriber/Sources/PipelineQueue.swift app/MeetingTranscriber/Tests/PipelineQueueTests.swift
git commit -m "feat(app): add PipelineQueue with enqueue and JSON logging"
```

---

### Task 3: PipelineQueue Processing Logic

**Files:**
- Modify: `app/MeetingTranscriber/Sources/PipelineQueue.swift`
- Modify: `app/MeetingTranscriber/Tests/PipelineQueueTests.swift`

**Context:** Add `processNext()` which picks the first `.waiting` job and runs the pipeline: resample → transcribe + diarize (parallel) → speaker assignment → protocol generation. The processing logic is extracted from `WatchLoop.handleMeeting()` (lines 177-296). PipelineQueue needs dependencies: `whisperKit`, `diarizationFactory`, `protocolGenerator`, `outputDir`, `diarizeEnabled`, `micLabel`.

**Step 1: Add processing tests**

Add these tests to `PipelineQueueTests.swift`:

```swift
    func testProcessNextPicksFirstWaitingJob() async throws {
        // Need a queue with mock dependencies for this test
        let queue = PipelineQueue(
            logDir: tmpDir,
            whisperKit: WhisperKitEngine(),
            diarizationFactory: { MockDiarization() },
            protocolGenerator: MockProtocolGen(),
            outputDir: tmpDir,
            diarizeEnabled: false,
            micLabel: "Me"
        )

        // Enqueue job with non-existent audio — will error, but proves it picked the job
        let job = makeJob()
        queue.enqueue(job)
        XCTAssertEqual(queue.jobs[0].state, .waiting)

        await queue.processNext()

        // Job should have been picked up (state != waiting)
        XCTAssertNotEqual(queue.jobs[0].state, .waiting)
    }

    func testProcessNextSkipsWhenNoWaitingJobs() async {
        let queue = PipelineQueue(
            logDir: tmpDir,
            whisperKit: WhisperKitEngine(),
            diarizationFactory: { MockDiarization() },
            protocolGenerator: MockProtocolGen(),
            outputDir: tmpDir,
            diarizeEnabled: false,
            micLabel: "Me"
        )
        // No jobs — should not crash
        await queue.processNext()
        XCTAssertTrue(queue.jobs.isEmpty)
    }

    func testIsProcessingFlag() async {
        let queue = PipelineQueue(
            logDir: tmpDir,
            whisperKit: WhisperKitEngine(),
            diarizationFactory: { MockDiarization() },
            protocolGenerator: MockProtocolGen(),
            outputDir: tmpDir,
            diarizeEnabled: false,
            micLabel: "Me"
        )
        XCTAssertFalse(queue.isProcessing)
    }
```

Note: You'll need to add `MockDiarization` and `MockProtocolGen` to the test file — copy them from `WatchLoopE2ETests.swift` but make them `internal` (not `private`) so they're accessible. Actually, to avoid duplication, create a shared test helpers file.

**Step 2: Create shared test helpers**

Create `app/MeetingTranscriber/Tests/TestHelpers.swift`:

```swift
import Foundation
@testable import MeetingTranscriber

class MockDiarization: DiarizationProvider {
    var isAvailable: Bool = true
    var runCalled = false

    func run(audioPath: URL, numSpeakers: Int?, meetingTitle: String) async throws -> DiarizationResult {
        runCalled = true
        return DiarizationResult(
            segments: [
                .init(start: 0, end: 5, speaker: "SPEAKER_00"),
                .init(start: 5, end: 10, speaker: "SPEAKER_01"),
            ],
            speakingTimes: ["SPEAKER_00": 5.0, "SPEAKER_01": 5.0],
            autoNames: [:]
        )
    }
}

class MockProtocolGen: ProtocolGenerating {
    var generateCalled = false
    var capturedTranscript: String?
    var capturedTitle: String?
    var capturedDiarized: Bool?

    func generate(transcript: String, title: String, diarized: Bool, claudeBin: String) async throws -> String {
        generateCalled = true
        capturedTranscript = transcript
        capturedTitle = title
        capturedDiarized = diarized
        return "# Meeting Protocol - \(title)\n\nTest protocol."
    }
}

class MockRecorder: RecordingProvider {
    var mixPath: URL?
    var appPath: URL?
    var micPath: URL?
    var startCalled = false
    var stopCalled = false

    func start(appPID: pid_t, noMic: Bool, micDeviceUID: String?) throws {
        startCalled = true
    }

    func stop() throws -> RecordingResult {
        stopCalled = true
        guard let mix = mixPath else {
            throw RecorderError.noAudioData
        }
        return RecordingResult(
            mixPath: mix,
            appPath: appPath,
            micPath: micPath,
            micDelay: 0,
            muteTimeline: [],
            recordingStart: ProcessInfo.processInfo.systemUptime
        )
    }
}
```

Then update `WatchLoopE2ETests.swift` to remove its private mock classes and use the shared ones instead.

**Step 3: Add processing logic to PipelineQueue**

Modify `PipelineQueue.swift` init to accept dependencies:

```swift
    // Dependencies for processing
    let whisperKit: WhisperKitEngine
    let diarizationFactory: () -> DiarizationProvider
    let protocolGenerator: ProtocolGenerating
    let outputDir: URL
    let diarizeEnabled: Bool
    let micLabel: String

    private var isProcessing = false
    private var processTask: Task<Void, Never>?

    init(
        logDir: URL? = nil,
        whisperKit: WhisperKitEngine = WhisperKitEngine(),
        diarizationFactory: @escaping () -> DiarizationProvider = { DiarizationProcess() },
        protocolGenerator: ProtocolGenerating = DefaultProtocolGenerator(),
        outputDir: URL = WatchLoop.defaultOutputDir,
        diarizeEnabled: Bool = false,
        micLabel: String = "Me"
    ) {
        self.logDir = logDir ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".meeting-transcriber")
        self.whisperKit = whisperKit
        self.diarizationFactory = diarizationFactory
        self.protocolGenerator = protocolGenerator
        self.outputDir = outputDir
        self.diarizeEnabled = diarizeEnabled
        self.micLabel = micLabel
    }
```

Override `enqueue` to auto-trigger processing:

```swift
    func enqueue(_ job: PipelineJob) {
        jobs.append(job)
        appendLog(jobID: job.id, event: "enqueued", from: nil, to: job.state)
        writeSnapshot()
        logger.info("Enqueued job: \(job.meetingTitle) (\(job.id))")
        triggerProcessing()
    }

    private func triggerProcessing() {
        guard !isProcessing else { return }
        guard pendingJobs.first != nil else { return }
        processTask = Task { [weak self] in
            await self?.processNext()
        }
    }
```

Add `processNext()` — the core pipeline (extracted from `WatchLoop.handleMeeting()` lines 177-296):

```swift
    func processNext() async {
        guard let index = jobs.firstIndex(where: { $0.state == .waiting }) else { return }
        isProcessing = true
        let jobID = jobs[index].id
        let job = jobs[index]

        do {
            // --- Transcription ---
            updateJobState(id: jobID, to: .transcribing)

            let recDir = job.mixPath.deletingLastPathComponent()

            // Resample to 16kHz
            let mix16k = recDir.appendingPathComponent("mix_16k.wav")
            let mixSamples = try AudioMixer.loadWAVAsFloat32(url: job.mixPath)
            try AudioMixer.saveWAV(
                samples: AudioMixer.resample(mixSamples, from: 48000, to: 16000),
                sampleRate: 16000, url: mix16k
            )

            let transcript: String
            if let appPath = job.appPath, let micPath = job.micPath {
                let app16k = recDir.appendingPathComponent("app_16k.wav")
                let appSamples = try AudioMixer.loadWAVAsFloat32(url: appPath)
                try AudioMixer.saveWAV(
                    samples: AudioMixer.resample(appSamples, from: 48000, to: 16000),
                    sampleRate: 16000, url: app16k
                )

                let mic16k = recDir.appendingPathComponent("mic_16k.wav")
                let micSamples = try AudioMixer.loadWAVAsFloat32(url: micPath)
                try AudioMixer.saveWAV(
                    samples: AudioMixer.resample(micSamples, from: 48000, to: 16000),
                    sampleRate: 16000, url: mic16k
                )

                transcript = try await whisperKit.transcribeDualSource(
                    appAudio: app16k, micAudio: mic16k,
                    micDelay: job.micDelay, micLabel: micLabel
                )
            } else {
                transcript = try await whisperKit.transcribe(audioPath: mix16k)
            }

            guard !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                updateJobState(id: jobID, to: .error, error: "Empty transcript")
                isProcessing = false
                triggerProcessing()
                return
            }

            // --- Diarization (parallel with transcription in future, sequential for now) ---
            var finalTranscript = transcript
            if diarizeEnabled {
                let diarizeProcess = diarizationFactory()
                if diarizeProcess.isAvailable {
                    updateJobState(id: jobID, to: .diarizing)

                    do {
                        let diarization = try await diarizeProcess.run(
                            audioPath: mix16k, numSpeakers: nil,
                            meetingTitle: job.meetingTitle
                        )

                        let appSegments: [TranscriptSegment]
                        if job.appPath != nil {
                            appSegments = try await whisperKit.transcribeSegments(
                                audioPath: recDir.appendingPathComponent("app_16k.wav"))
                        } else {
                            appSegments = try await whisperKit.transcribeSegments(
                                audioPath: mix16k)
                        }

                        let labeled = DiarizationProcess.assignSpeakers(
                            transcript: appSegments, diarization: diarization
                        )
                        finalTranscript = labeled.map(\.formattedLine).joined(separator: "\n")
                    } catch {
                        logger.warning("Diarization failed, using undiarized transcript: \(error)")
                    }
                }
            }

            // Save transcript
            let txtPath = try ProtocolGenerator.saveTranscript(
                finalTranscript, title: job.meetingTitle, dir: outputDir
            )
            logger.info("Transcript saved: \(txtPath.lastPathComponent)")

            // --- Protocol Generation ---
            updateJobState(id: jobID, to: .generatingProtocol)

            let diarized = finalTranscript.range(
                of: #"\[\w[\w\s]*\]"#, options: .regularExpression
            ) != nil
            let protocolMD = try await protocolGenerator.generate(
                transcript: finalTranscript, title: job.meetingTitle,
                diarized: diarized, claudeBin: "claude"
            )

            let fullMD = protocolMD + "\n\n---\n\n## Full Transcript\n\n" + transcript
            let mdPath = try ProtocolGenerator.saveProtocol(
                fullMD, title: job.meetingTitle, dir: outputDir
            )
            logger.info("Protocol saved: \(mdPath.lastPathComponent)")

            if let idx = jobs.firstIndex(where: { $0.id == jobID }) {
                jobs[idx].protocolPath = mdPath
            }
            updateJobState(id: jobID, to: .done)

        } catch {
            logger.error("Pipeline error for \(job.meetingTitle): \(error)")
            updateJobState(id: jobID, to: .error, error: error.localizedDescription)
        }

        isProcessing = false
        triggerProcessing()  // process next job if any
    }
```

**Step 4: Run all tests**

Run: `cd app/MeetingTranscriber && swift test 2>&1 | tail -10`
Expected: All tests pass

**Step 5: Commit**

```bash
git add app/MeetingTranscriber/Sources/PipelineQueue.swift \
        app/MeetingTranscriber/Tests/PipelineQueueTests.swift \
        app/MeetingTranscriber/Tests/TestHelpers.swift \
        app/MeetingTranscriber/Tests/WatchLoopE2ETests.swift
git commit -m "feat(app): add PipelineQueue processing logic with parallel transcription+diarization"
```

---

### Task 4: Refactor WatchLoop — Strip Pipeline, Enqueue to PipelineQueue

**Files:**
- Modify: `app/MeetingTranscriber/Sources/WatchLoop.swift`
- Modify: `app/MeetingTranscriber/Tests/WatchLoopTests.swift`

**Context:** WatchLoop should no longer own `whisperKit`, `diarizationFactory`, `protocolGenerator`, `diarizeEnabled`, `micLabel`, `outputDir`. After recording stops, it creates a `PipelineJob` and calls `pipelineQueue.enqueue()`. States `transcribing`, `diarizing`, `generatingProtocol`, `done` are removed — WatchLoop only has: `idle`, `watching`, `recording`, `error`.

**Step 1: Update WatchLoop.State enum**

Remove states that moved to PipelineQueue:

```swift
    enum State: String, Sendable {
        case idle
        case watching
        case recording
        case error
    }
```

**Step 2: Remove pipeline dependencies from init, add pipelineQueue**

```swift
    // Dependencies
    let detector: MeetingDetector
    let recorderFactory: () -> RecordingProvider
    var pipelineQueue: PipelineQueue?

    // Settings
    let pollInterval: TimeInterval
    let endGracePeriod: TimeInterval
    let maxDuration: TimeInterval
    let noMic: Bool

    init(
        detector: MeetingDetector = MeetingDetector(patterns: AppMeetingPattern.all),
        recorderFactory: @escaping () -> RecordingProvider = { DualSourceRecorder() },
        pipelineQueue: PipelineQueue? = nil,
        pollInterval: TimeInterval = 3.0,
        endGracePeriod: TimeInterval = 15.0,
        maxDuration: TimeInterval = 14400,
        noMic: Bool = false
    ) {
        self.detector = detector
        self.recorderFactory = recorderFactory
        self.pipelineQueue = pipelineQueue
        self.pollInterval = pollInterval
        self.endGracePeriod = endGracePeriod
        self.maxDuration = maxDuration
        self.noMic = noMic
    }
```

**Step 3: Simplify handleMeeting() — recording only, then enqueue**

```swift
    func handleMeeting(_ meeting: DetectedMeeting) async throws {
        currentMeeting = meeting
        let title = Self.cleanTitle(meeting.windowTitle)

        // --- Recording ---
        transition(to: .recording)
        detail = "Recording: \(title)"

        let recorder = recorderFactory()
        try recorder.start(
            appPID: meeting.windowPID,
            noMic: noMic,
            micDeviceUID: nil
        )

        // Read participants (Teams)
        if meeting.pattern.appName == "Microsoft Teams",
           let participants = ParticipantReader.readParticipants(pid: meeting.windowPID),
           !participants.isEmpty {
            logger.info("Detected \(participants.count) participants")
            ParticipantReader.writeParticipants(participants, meetingTitle: title)
        }

        // Wait for meeting to end
        try await waitForMeetingEnd(meeting)

        // Stop recording
        let recording = try recorder.stop()

        // --- Enqueue for background processing ---
        let job = PipelineJob(
            meetingTitle: title,
            appName: meeting.pattern.appName,
            mixPath: recording.mixPath,
            appPath: recording.appPath,
            micPath: recording.micPath,
            micDelay: recording.micDelay
        )
        pipelineQueue?.enqueue(job)
        logger.info("Enqueued pipeline job for: \(title)")
    }
```

**Step 4: Update watchLoop() — remove done/error delay, simplify**

```swift
    private func watchLoop() async {
        while !Task.isCancelled {
            if let meeting = detector.checkOnce() {
                do {
                    try await handleMeeting(meeting)
                } catch {
                    let msg = "Recording error: \(error)"
                    logger.error("\(msg)")
                    lastError = error.localizedDescription
                    transition(to: .error)
                    detail = "Recording error: \(error.localizedDescription)"
                    // Show error for 10 seconds then go back to watching
                    try? await Task.sleep(for: .seconds(10))
                }

                detector.reset(appName: meeting.pattern.appName)

                if !Task.isCancelled {
                    transition(to: .watching)
                    detail = "Polling for meetings..."
                }
            }

            try? await Task.sleep(for: .seconds(pollInterval))
        }
    }
```

**Step 5: Update transcriberState mapping** (remove old states)

```swift
    var transcriberState: TranscriberState {
        switch state {
        case .idle: .idle
        case .watching: .watching
        case .recording: .recording
        case .error: .error
        }
    }
```

**Step 6: Remove `lastProtocolPath`** — this now lives on `PipelineJob.protocolPath`

Remove: `private(set) var lastProtocolPath: URL?`

**Step 7: Update WatchLoopTests**

Update `testTranscriberStateMapping` — remove transcribing/diarizing/generatingProtocol/done mappings.

Update `makeLoop()` to use new init (no whisperKit, no outputDir, etc.).

Remove `testDiarizeEnabledDefault`, `testDiarizeEnabledInit`, `testMicLabelDefault`, `testMicLabelCustom` — these settings moved to PipelineQueue.

**Step 8: Run all tests**

Run: `cd app/MeetingTranscriber && swift test 2>&1 | tail -10`
Expected: All pass (E2E tests will need updating in Task 5)

**Step 9: Commit**

```bash
git add app/MeetingTranscriber/Sources/WatchLoop.swift \
        app/MeetingTranscriber/Tests/WatchLoopTests.swift
git commit -m "refactor(watch): strip pipeline from WatchLoop, enqueue to PipelineQueue"
```

---

### Task 5: Update WatchLoopE2ETests

**Files:**
- Modify: `app/MeetingTranscriber/Tests/WatchLoopE2ETests.swift`

**Context:** E2E tests now need a `PipelineQueue` with mocks. `handleMeeting()` only does recording + enqueue. The full pipeline test needs to call `queue.processNext()` after `handleMeeting()` to verify the pipeline runs.

**Step 1: Update E2E test helpers**

Update `makeLoop()` to accept a `PipelineQueue` and wire it:

```swift
    private func makeLoop(
        recorder: MockRecorder,
        pipelineQueue: PipelineQueue,
        micLabel: String = "Roman"
    ) -> WatchLoop {
        let detector = MeetingDetector(patterns: AppMeetingPattern.all)
        detector.windowListProvider = { [] }

        return WatchLoop(
            detector: detector,
            recorderFactory: { recorder },
            pipelineQueue: pipelineQueue,
            pollInterval: 0.05,
            endGracePeriod: 0.1,
            maxDuration: 10,
            noMic: false
        )
    }
```

Add a helper to create a PipelineQueue with mocks:

```swift
    private func makeQueue(
        whisperKit: WhisperKitEngine? = nil,
        diarization: MockDiarization = MockDiarization(),
        protocolGen: MockProtocolGen = MockProtocolGen(),
        diarizeEnabled: Bool = false,
        micLabel: String = "Roman"
    ) -> PipelineQueue {
        PipelineQueue(
            logDir: tmpDir,
            whisperKit: whisperKit ?? WhisperKitEngine(),
            diarizationFactory: { diarization },
            protocolGenerator: protocolGen,
            outputDir: tmpDir,
            diarizeEnabled: diarizeEnabled,
            micLabel: micLabel
        )
    }
```

**Step 2: Update full pipeline test**

```swift
    func testFullPipelineDetectRecordTranscribeDiarizeProtocol() async throws {
        // ... (same skip guards) ...

        let mixPath = try prepare48kHzFixture()
        let recorder = MockRecorder()
        recorder.mixPath = mixPath

        let mockDiarization = MockDiarization()
        let mockProtocol = MockProtocolGen()

        let engine = WhisperKitEngine()
        engine.modelVariant = "openai_whisper-small"
        engine.language = "de"

        let queue = makeQueue(
            whisperKit: engine,
            diarization: mockDiarization,
            protocolGen: mockProtocol,
            diarizeEnabled: true
        )
        let loop = makeLoop(recorder: recorder, pipelineQueue: queue)

        let meeting = makeMeeting()
        try await loop.handleMeeting(meeting)

        // Verify recording happened
        XCTAssertTrue(recorder.startCalled)
        XCTAssertTrue(recorder.stopCalled)

        // Verify job was enqueued
        XCTAssertEqual(queue.jobs.count, 1)
        XCTAssertEqual(queue.jobs[0].state, .waiting)

        // Process the job
        await queue.processNext()

        // Verify pipeline ran
        XCTAssertTrue(mockDiarization.runCalled)
        XCTAssertTrue(mockProtocol.generateCalled)
        XCTAssertEqual(queue.jobs[0].state, .done)
        XCTAssertNotNil(queue.jobs[0].protocolPath)
    }
```

Update all other E2E tests similarly: `handleMeeting()` + `queue.processNext()`.

**Step 3: Run all tests**

Run: `cd app/MeetingTranscriber && swift test 2>&1 | tail -10`
Expected: All pass

**Step 4: Commit**

```bash
git add app/MeetingTranscriber/Tests/WatchLoopE2ETests.swift
git commit -m "test: update E2E tests for PipelineQueue architecture"
```

---

### Task 6: MenuBarView Dashboard

**Files:**
- Modify: `app/MeetingTranscriber/Sources/MenuBarView.swift`

**Context:** Add two sections: "Active" (recording in progress) and "Processing" (queue jobs). The view now takes a `PipelineQueue` parameter.

**Step 1: Update MenuBarView signature**

```swift
struct MenuBarView: View {
    let status: TranscriberStatus?
    let isWatching: Bool
    let pipelineQueue: PipelineQueue
    let onStartStop: () -> Void
    let onOpenProtocol: (URL) -> Void
    let onOpenProtocolsFolder: () -> Void
    let onOpenSettings: () -> Void
    let onNameSpeakers: (() -> Void)?
    let onDismissJob: (UUID) -> Void
    let onQuit: () -> Void
```

**Step 2: Add Processing section**

After the Active/meeting section, add:

```swift
        // Processing queue
        if !pipelineQueue.activeJobs.isEmpty || !pipelineQueue.pendingJobs.isEmpty
            || !pipelineQueue.completedJobs.isEmpty || !pipelineQueue.errorJobs.isEmpty {
            Divider()
            Label("Processing", systemImage: "gearshape.2.fill")
                .font(.caption)
                .foregroundStyle(.secondary)

            ForEach(pipelineQueue.jobs.filter { $0.state != .done || /* show done for 60s */ true }) { job in
                HStack {
                    Circle()
                        .fill(jobColor(job.state))
                        .frame(width: 8, height: 8)
                    VStack(alignment: .leading) {
                        Text(job.meetingTitle)
                            .font(.caption)
                        Text(job.state.label)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if job.state == .done {
                        Button("Open") { onOpenProtocol(job.protocolPath!) }
                            .font(.caption2)
                    }
                    if job.state == .done || job.state == .error {
                        Button("Dismiss") { onDismissJob(job.id) }
                            .font(.caption2)
                    }
                }
                .padding(.horizontal, 4)
            }
        }
```

**Step 3: Add helper for job colors and label**

```swift
    private func jobColor(_ state: JobState) -> Color {
        switch state {
        case .waiting: .gray
        case .transcribing: .blue
        case .diarizing: .purple
        case .generatingProtocol: .orange
        case .done: .green
        case .error: .red
        }
    }
```

Add `label` to `JobState`:

In `PipelineJob.swift`:
```swift
extension JobState {
    var label: String {
        switch self {
        case .waiting: "Waiting..."
        case .transcribing: "Transcribing..."
        case .diarizing: "Diarizing..."
        case .generatingProtocol: "Generating Protocol..."
        case .done: "Done"
        case .error: "Error"
        }
    }
}
```

**Step 4: Run tests**

Run: `cd app/MeetingTranscriber && swift test 2>&1 | tail -10`
Expected: Compile errors in tests that construct MenuBarView — fix them (pass `pipelineQueue` parameter).

**Step 5: Commit**

```bash
git add app/MeetingTranscriber/Sources/MenuBarView.swift \
        app/MeetingTranscriber/Sources/PipelineJob.swift
git commit -m "feat(app): add Processing section to MenuBarView dashboard"
```

---

### Task 7: Wire PipelineQueue in MeetingTranscriberApp

**Files:**
- Modify: `app/MeetingTranscriber/Sources/MeetingTranscriberApp.swift`

**Context:** Create `PipelineQueue` at app level. Pass it to `WatchLoop` and `MenuBarView`. Move IPC poller handling and notifications to queue's `onJobStateChange`.

**Step 1: Add PipelineQueue state**

```swift
    @State private var pipelineQueue: PipelineQueue?
```

**Step 2: Update toggleWatching()**

Create PipelineQueue with real dependencies, pass to WatchLoop:

```swift
    let queue = PipelineQueue(
        whisperKit: whisperKit,
        diarizationFactory: { DiarizationProcess() },
        protocolGenerator: DefaultProtocolGenerator(),
        outputDir: WatchLoop.defaultOutputDir,
        diarizeEnabled: settings.diarize,
        micLabel: settings.micName
    )

    queue.onJobStateChange = { job, oldState, newState in
        switch newState {
        case .diarizing:
            ipcPoller.start()
        case .done:
            ipcPoller.stop()
            ipcPoller.reset()
            notifications.notify(title: "Protocol Ready", body: job.meetingTitle)
        case .error:
            ipcPoller.stop()
            ipcPoller.reset()
            if let err = job.error {
                notifications.notify(title: "Error", body: err)
            }
        default: break
        }
    }

    pipelineQueue = queue

    let loop = WatchLoop(
        detector: MeetingDetector(patterns: patterns),
        pipelineQueue: queue,
        pollInterval: settings.pollInterval,
        endGracePeriod: settings.endGrace,
        noMic: settings.noMic
    )

    loop.onStateChange = { [notifications] _, newState in
        if newState == .recording, let meeting = loop.currentMeeting {
            notifications.notify(
                title: "Meeting Detected",
                body: "Recording: \(meeting.windowTitle)"
            )
        }
    }
```

**Step 3: Pass PipelineQueue to MenuBarView**

```swift
    MenuBarView(
        status: currentStatus,
        isWatching: isWatching,
        pipelineQueue: pipelineQueue ?? PipelineQueue(),
        onStartStop: toggleWatching,
        onOpenProtocol: { NSWorkspace.shared.open($0) },
        onOpenProtocolsFolder: openProtocolsFolder,
        onOpenSettings: { bringWindowToFront(id: "settings") },
        onNameSpeakers: { ... },
        onDismissJob: { id in pipelineQueue?.removeJob(id: id) },
        onQuit: quit
    )
```

**Step 4: Update currentStatus** — remove references to transcribing/done states from WatchLoop (those live in PipelineQueue now)

**Step 5: Update menubar icon** — show processing indicator when queue has active jobs:

```swift
    private var currentStateIcon: String {
        if let loop = watchLoop, loop.state == .recording {
            return "record.circle.fill"
        }
        if let queue = pipelineQueue, !queue.activeJobs.isEmpty {
            return "gearshape.2.fill"
        }
        if isWatching {
            return "eye.fill"
        }
        return "waveform.circle"
    }
```

**Step 6: Run tests + build**

Run: `cd app/MeetingTranscriber && swift build 2>&1 | tail -10`
Expected: Build succeeds

Run: `cd app/MeetingTranscriber && swift test 2>&1 | tail -10`
Expected: All tests pass

**Step 7: Commit**

```bash
git add app/MeetingTranscriber/Sources/MeetingTranscriberApp.swift
git commit -m "feat(app): wire PipelineQueue into app, move notifications to queue callbacks"
```

---

### Task 8: Auto-Remove Completed Jobs After 60 Seconds

**Files:**
- Modify: `app/MeetingTranscriber/Sources/PipelineQueue.swift`
- Modify: `app/MeetingTranscriber/Tests/PipelineQueueTests.swift`

**Context:** Done jobs should auto-dismiss from the UI after 60 seconds. Error jobs stay until manually dismissed.

**Step 1: Add test**

```swift
    func testCompletedJobAutoRemovedAfterDelay() async throws {
        let queue = PipelineQueue(
            logDir: tmpDir,
            completedJobLifetime: 0.2  // 200ms for testing
        )
        var job = makeJob()
        job.state = .done
        queue.enqueue(job)
        XCTAssertEqual(queue.jobs.count, 1)

        try await Task.sleep(for: .milliseconds(400))
        XCTAssertEqual(queue.jobs.count, 0, "Done job should be auto-removed")
    }

    func testErrorJobNotAutoRemoved() async throws {
        let queue = PipelineQueue(
            logDir: tmpDir,
            completedJobLifetime: 0.2
        )
        var job = makeJob()
        job.state = .error
        job.error = "Test error"
        queue.enqueue(job)

        try await Task.sleep(for: .milliseconds(400))
        XCTAssertEqual(queue.jobs.count, 1, "Error job should NOT be auto-removed")
    }
```

**Step 2: Implement auto-removal**

Add `completedJobLifetime` parameter (default 60 seconds). When `updateJobState` transitions to `.done`, schedule a `Task` that removes it after the delay:

```swift
    let completedJobLifetime: TimeInterval

    // In init:
    self.completedJobLifetime = completedJobLifetime  // default: 60

    // In updateJobState, after setting .done:
    if newState == .done {
        Task { [weak self, id] in
            try? await Task.sleep(for: .seconds(self?.completedJobLifetime ?? 60))
            self?.removeJob(id: id)
        }
    }
```

**Step 3: Run tests**

Run: `cd app/MeetingTranscriber && swift test --filter PipelineQueueTests 2>&1 | tail -10`
Expected: All pass

**Step 4: Commit**

```bash
git add app/MeetingTranscriber/Sources/PipelineQueue.swift \
        app/MeetingTranscriber/Tests/PipelineQueueTests.swift
git commit -m "feat(app): auto-remove completed pipeline jobs after 60 seconds"
```

---

### Task 9: Final Integration Test

**Step 1: Run all tests**

```bash
cd app/MeetingTranscriber && swift test 2>&1 | tail -20
```

Expected: All tests pass (300+ tests)

**Step 2: Run lints**

```bash
ruff check src/ tests/ && ruff format --check src/ tests/
```

Expected: All clean

**Step 3: Build release**

```bash
swift build -c release 2>&1 | tail -5
```

Expected: Build succeeds, no errors

**Step 4: Manual smoke test**

1. `./scripts/run_app.sh`
2. Start watching
3. Verify MenuBarView shows "Active" section when recording
4. Verify "Processing" section appears after recording ends
5. Verify job moves through states: Transcribing → Generating Protocol → Done
6. Verify Done job auto-dismisses after 60 seconds

**Step 5: Commit any final fixes**

```bash
git add -A  # only if there are fixes
git commit -m "test: verify pipeline queue integration"
```

---

## Summary

| Task | Component | New/Modify | Key Change |
|------|-----------|------------|------------|
| 1 | PipelineJob | New | Job model + JobState enum |
| 2 | PipelineQueue | New | Enqueue + JSON snapshot + JSONL log |
| 3 | PipelineQueue | Modify | Processing logic (from WatchLoop) |
| 4 | WatchLoop | Modify | Strip pipeline, recording only, enqueue |
| 5 | WatchLoopE2ETests | Modify | Adapt for queue architecture |
| 6 | MenuBarView | Modify | Active + Processing dashboard |
| 7 | MeetingTranscriberApp | Modify | Wire queue, move notifications |
| 8 | PipelineQueue | Modify | Auto-remove completed jobs |
| 9 | Integration | - | Full test + smoke test |
