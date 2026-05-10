import AVFoundation
@testable import MeetingTranscriber
import XCTest

/// End-to-end coverage for the auto-detect (`handleMeeting`) call site of the
/// record-only branch. The manual-recording call site is already covered by
/// `WatchLoopTests.test_recordOnly_*`, but those tests use empty `Data()` for
/// the recorder output. These tests run with a real fixture WAV so a regression
/// that breaks file move semantics or sidecar JSON shape surfaces against
/// realistic content. They also exercise the auto-detect entry point (vs the
/// existing manual-recording entry point) so a refactor that touches one
/// `enqueueRecording` caller without the other is caught.
@MainActor
final class RecordOnlyE2ETests: XCTestCase { // swiftlint:disable:this balanced_xctest_lifecycle
    // swiftlint:disable implicitly_unwrapped_optional
    private var tmpDir: URL!
    private var recorder: MockRecorder!
    private var queue: PipelineQueue!
    private var notifier: RecordingNotifier!
    // swiftlint:enable implicitly_unwrapped_optional

    private static let basename = "20260503_120000"

    override func setUp() async throws {
        try await super.setUp()
        tmpDir = try makeTempDirectory(prefix: "recordonly_e2e")
        recorder = try makeRecorderWithFixtureWAVs(basename: Self.basename)
        queue = PipelineQueue(logDir: tmpDir)
        notifier = RecordingNotifier()
    }

    // MARK: - Tests

    func test_handleMeeting_recordOnly_writesSidecarAndSkipsPipeline() async throws {
        let outputDir = tmpDir.appendingPathComponent("output", isDirectory: true)
        let loop = makeRecordOnlyLoop(outputDir: outputDir)

        try await loop.handleMeeting(makeMeeting())

        XCTAssertTrue(queue.jobs.isEmpty, "record-only must not enqueue a pipeline job")
        XCTAssertTrue(notifier.calls.isEmpty, "no failure notification on the happy path")

        let sidecarURL = outputDir.appendingPathComponent("\(Self.basename)_meta.json")
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: sidecarURL.path),
            "sidecar JSON must land in the output directory",
        )

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let sidecar = try decoder.decode(RecordingSidecar.self, from: Data(contentsOf: sidecarURL))
        XCTAssertEqual(sidecar.version, RecordingSidecar.currentVersion)
        XCTAssertEqual(sidecar.files.mix, "\(Self.basename)_mix.wav")
        XCTAssertEqual(sidecar.files.app, "\(Self.basename)_app.wav")
        XCTAssertEqual(sidecar.files.mic, "\(Self.basename)_mic.wav")
        XCTAssertLessThanOrEqual(sidecar.startedAt, sidecar.stoppedAt)

        // Round-trip the moved mix file through AVAudioFile to catch corruption
        // in the move step. Lower bound is loose but tight enough to detect
        // silent truncation — fixture is 17 s @ 16 kHz ≈ 272 k frames.
        let movedMix = outputDir.appendingPathComponent("\(Self.basename)_mix.wav")
        let avFile = try AVAudioFile(forReading: movedMix)
        XCTAssertEqual(Int(avFile.processingFormat.sampleRate), 16000)
        XCTAssertGreaterThan(avFile.length, 100_000)
    }

    func test_handleMeeting_recordOnly_writeFailure_notifiesAndDoesNotEnqueue() async throws {
        // `/dev/null/...` makes `createDirectory(at:)` throw, hitting the
        // error branch in `writeRecordOnlySidecar`.
        let unwritable = URL(fileURLWithPath: "/dev/null/cannot-write")
        let loop = makeRecordOnlyLoop(outputDir: unwritable)

        try await loop.handleMeeting(makeMeeting())

        XCTAssertTrue(queue.jobs.isEmpty, "still no enqueue when sidecar write fails")
        XCTAssertEqual(notifier.calls.count, 1, "user must be notified about lost record-only output")
        XCTAssertEqual(notifier.calls.first?.title, "Record-only output failed")
    }

    // MARK: - Helpers

    /// Copy the canonical two-speaker fixture into tmpDir under three
    /// recorder-shaped names. We copy (not point at the shared fixture
    /// directly) because `WatchLoop.move()` does `moveItem` and would
    /// destroy the fixture for any subsequent test.
    private func makeRecorderWithFixtureWAVs(basename: String) throws -> MockRecorder {
        let fixture = fixtureURL()
        try XCTSkipUnless(
            FileManager.default.fileExists(atPath: fixture.path),
            "Test fixture missing: \(fixture.path)",
        )

        let mix = tmpDir.appendingPathComponent("\(basename)_mix.wav")
        let app = tmpDir.appendingPathComponent("\(basename)_app.wav")
        let mic = tmpDir.appendingPathComponent("\(basename)_mic.wav")
        for dst in [mix, app, mic] {
            try FileManager.default.copyItem(at: fixture, to: dst)
        }

        let recorder = MockRecorder()
        recorder.mixPath = mix
        recorder.appPath = app
        recorder.micPath = mic
        return recorder
    }

    private func makeRecordOnlyLoop(outputDir: URL) -> WatchLoop {
        let detector = PowerAssertionDetector()
        // Empty assertion list → meeting "ends" on first poll.
        detector.assertionProvider = { [:] }

        let loop = WatchLoop(
            detector: detector,
            recorderFactory: { self.recorder },
            pipelineQueue: queue,
            pollInterval: 0.05,
            endGracePeriod: 0.1,
            maxDuration: 10,
            noMic: false,
            recordOnly: { true },
            recordOnlyDestination: { .unscoped(outputDir) },
            notifier: notifier,
        )
        loop.permissionChecker = {
            HealthCheckResult(screenRecording: .healthy, microphone: .healthy)
        }
        return loop
    }

    private func makeMeeting(pid: pid_t = 9999) -> DetectedMeeting {
        DetectedMeeting(
            pattern: .teams,
            windowTitle: "Standup | Microsoft Teams",
            ownerName: "Microsoft Teams",
            windowPID: pid,
        )
    }
}
