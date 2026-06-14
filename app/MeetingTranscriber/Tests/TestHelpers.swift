@preconcurrency import AVFoundation
import Foundation
@testable import MeetingTranscriber
import XCTest

// MARK: - Temp-Directory / Temp-File Helpers

extension XCTestCase {
    /// Create a unique temp directory under `FileManager.default.temporaryDirectory`
    /// and register an automatic cleanup with `addTeardownBlock`. The dir is
    /// removed regardless of whether tearDown is async, sync, or absent.
    func makeTempDirectory(prefix: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(prefix)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: url)
        }
        return url
    }

    /// Reserve a unique temp file URL under `FileManager.default.temporaryDirectory`
    /// and register an automatic cleanup with `addTeardownBlock`. The file is
    /// NOT pre-created — only the URL is reserved.
    /// `suffix` typically includes the extension, e.g. `".wav"`.
    func makeTempFile(suffix: String) -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString)\(suffix)")
        addTeardownBlock {
            try? FileManager.default.removeItem(at: url)
        }
        return url
    }
}

// MARK: - Async Polling Helper

extension XCTestCase {
    /// Yields repeatedly until `condition()` is true or `timeout` elapses.
    /// Needed for tests that await operations spawning a `Task { @MainActor in … }`
    /// (e.g. AppState's `withObservationTracking` re-arm, AVCaptureDevice
    /// permission prompts) — a single `Task.yield()` isn't always enough to
    /// drain the runloop before the assertion fires.
    @MainActor
    func waitFor(
        _ condition: @autoclosure () -> Bool,
        timeout: Duration = .milliseconds(500),
    ) async {
        let deadline = ContinuousClock.now + timeout
        while !condition(), ContinuousClock.now < deadline {
            await Task.yield()
        }
    }

    /// Async-condition overload for conditions that must `await` (e.g. reading
    /// actor-isolated test-double state). Polls with a short sleep instead of
    /// a bare yield so the awaited actor gets real scheduling windows.
    @MainActor
    func waitFor(
        _ condition: () async -> Bool,
        timeout: Duration = .seconds(5),
    ) async {
        let deadline = ContinuousClock.now + timeout
        while await !condition(), ContinuousClock.now < deadline {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }
}

// MARK: - Fixture URL Helper

extension XCTestCase {
    /// Resolve a fixture file in `Tests/Fixtures/` relative to TestHelpers.swift.
    /// All callers share the same Fixtures dir. The default `two_speakers_de.wav`
    /// is the canonical German two-speaker fixture used by ASR-engine E2E tests.
    func fixtureURL(_ name: String = "two_speakers_de.wav") -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures")
            .appendingPathComponent(name)
    }
}

/// Decode a fixture WAV into a 16 kHz mono Float32 array via the
/// production `AudioMixer` helpers — exercising the same load+resample
/// path the batch pipeline uses, so a regression in either landing on
/// only-test code is unlikely. Free function (not an XCTestCase extension)
/// so `@MainActor`-isolated test classes can call it without sending a
/// non-Sendable `self` across the isolation boundary.
func loadFixtureAs16kMono(_ url: URL) async throws -> [Float] {
    let (raw, srcRate) = try await AudioMixer.loadAudioAsFloat32(url: url)
    guard srcRate != 16000 else { return raw }
    return AudioMixer.resample(raw, from: srcRate, to: 16000)
}

// MARK: - E2E Opt-In Gate

/// Skip in CI unless the dedicated `e2e.yml` workflow opted in via `E2E_ENABLED=1`.
/// Free function so the gate is unit-testable without an XCTestCase context.
func shouldSkipForE2EGate(env: [String: String]) -> Bool {
    let isCI = env["CI"] != nil
    let optedIn = env["E2E_ENABLED"] == "1"
    return isCI && !optedIn
}

extension XCTestCase {
    func skipIfCIWithoutE2EOptIn(_ reason: String) throws {
        try XCTSkipIf(
            shouldSkipForE2EGate(env: ProcessInfo.processInfo.environment),
            "Skipping in CI: \(reason)",
        )
    }
}

// MARK: - Quality-Suite Helpers

extension XCTestCase {
    /// Skip unless the dedicated quality job opted in via `RUN_QUALITY_TESTS=1`.
    /// Quality tests pull production-size models (~1 GB) and are gated so a
    /// normal `swift test` on a dev machine doesn't pay that cost.
    func skipUnlessQualityRun() throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["RUN_QUALITY_TESTS"] == "1",
            "Set RUN_QUALITY_TESTS=1 to run quality regression tests",
        )
    }

    /// App version recorded in `QualityResult` rows. Bundle's
    /// `CFBundleShortVersionString` when hosted in the app, "dev" under raw
    /// `swift test`.
    var qualityAppVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
            ?? "dev"
    }

    /// Standard WER quality flow against a ground-truth fixture using an
    /// already-loaded engine. Computes WER, appends a `QualityResult` row to
    /// the shared writer, flushes eagerly so a later test crash doesn't lose
    /// data, then soft-asserts the WER is below `threshold`.
    ///
    /// Engine instantiation, model load, and `modelState` verification stay
    /// in the calling test method because each engine has different load
    /// semantics and configuration knobs (WhisperKit needs `modelVariant +
    /// language`; Parakeet auto-detects; Qwen3 is `@available(macOS 15+)`).
    @MainActor
    func runWERAgainstFixture(
        named fixture: String,
        engine: any TranscribingEngine,
        engineLabel: String,
        modelVariant: String?,
        threshold: Double,
    ) async throws {
        let truth = try GroundTruth.load(named: fixture)
        try XCTSkipUnless(
            FileManager.default.fileExists(atPath: truth.audioURL.path),
            "Audio fixture missing: \(truth.audioURL.path)",
        )

        let started = Date()
        let segments = try await engine.transcribeSegments(audioPath: truth.audioURL)
        let hypothesis = segments.map(\.text).joined(separator: " ")
        let breakdown = WERCalculator.werBreakdown(
            reference: truth.text,
            hypothesis: hypothesis,
        )

        let elapsed = Date().timeIntervalSince(started)
        QualityResultsWriter.shared.append(
            QualityResult(
                engine: engineLabel,
                fixture: fixture,
                modelVariant: modelVariant,
                wer: breakdown.wer,
                der: nil,
                werBreakdown: .init(breakdown),
                derBreakdown: nil,
                appVersion: qualityAppVersion,
                timestamp: ISO8601DateFormatter().string(from: started),
                durationSeconds: elapsed,
            ),
        )
        _ = try? QualityResultsWriter.shared.flush()

        XCTAssertLessThan(
            breakdown.wer,
            threshold,
            "\(engineLabel) WER too high: \(breakdown.wer) — hypothesis was: \(hypothesis)",
        )
    }
}

// MARK: - WatchLoop / AppState Helpers

/// Returns a MeetingDetector with no patterns — never matches any window.
func makeSilentDetector() -> MeetingDetector {
    MeetingDetector(patterns: [])
}

/// Creates a WatchLoop backed by a MockRecorder and a silent detector.
/// Assign the returned loop to `appState.watching.watchLoop` in tests that need
/// an active loop without calling toggleWatching() (which requires Permissions).
@MainActor
func makeTestWatchLoop(
    pipelineQueue: PipelineQueue? = nil,
    recordOnly: @escaping () -> Bool = { false },
    recordOnlyOutputDir: @escaping () -> URL = { AppPaths.recordingsDir },
    notifier: any AppNotifying = SilentNotifier(),
    noMic: Bool = false,
    micDeviceUID: String? = nil,
) -> (WatchLoop, MockRecorder) {
    let recorder = MockRecorder()
    recorder.mixPath = URL(fileURLWithPath: "/tmp/test_mix.wav")
    let loop = WatchLoop(
        detector: makeSilentDetector(),
        recorderFactory: { recorder },
        pipelineQueue: pipelineQueue,
        pollInterval: 0.05,
        endGracePeriod: 0.1,
        noMic: noMic,
        micDeviceUID: micDeviceUID,
        recordOnly: recordOnly,
        recordOnlyDestination: { .unscoped(recordOnlyOutputDir()) },
        notifier: notifier,
    )
    loop.permissionChecker = {
        HealthCheckResult(screenRecording: .healthy, microphone: .healthy)
    }
    return (loop, recorder)
}

// MARK: - TestClock for WatchLoop timing

/// Deterministic virtual clock for `WatchLoop` async timing tests. Inject
/// the `now`/`sleep` closures into `WatchLoop(..., now:, sleep:)` and the
/// timing-sensitive paths (`waitForMeetingEnd`, `monitorManualRecording`,
/// `watchLoop`) run instantly: every `sleep(_:)` resolves after a single
/// `Task.yield()` while advancing the virtual clock by the requested
/// interval. Tests assert on poll counts and `clock.now`'s elapsed delta
/// rather than wall-clock time.
///
/// Not thread-safe by design — designed for `@MainActor` callers (which
/// `WatchLoop` already is). Cross-actor use would need a lock.
@MainActor
final class TestClock {
    private(set) var now: Date

    init(start: Date = Date(timeIntervalSince1970: 1_000_000)) {
        self.now = start
    }

    /// Advance the virtual clock and yield once so any awaiting task gets
    /// a chance to resume. Doesn't throw, but the injection closure into
    /// `WatchLoop(..., sleep:)` (which is `async throws`) wraps the call
    /// — Swift accepts a non-throwing call inside a throwing closure body.
    func sleep(for interval: TimeInterval) async {
        now = now.addingTimeInterval(interval)
        await Task.yield()
    }
}

/// Tiny counter for tests that need to observe how many times a captured
/// closure was invoked. Class reference lets a non-Sendable closure mutate
/// the count without an `inout`/escaping-capture dance.
final class ManagedCounter {
    private(set) var value = 0
    func increment() -> Int {
        value += 1
        return value
    }
}

// MARK: - AppNotifying spy

/// Records all notify() calls for assertions.
final class RecordingNotifier: AppNotifying {
    private(set) var calls: [(title: String, body: String)] = []

    func notify(title: String, body: String) {
        calls.append((title: title, body: body))
    }
}

// MARK: - Shared Mock Classes

/// Mock recorder that returns a pre-prepared fixture WAV as the recording result.
@MainActor
class MockRecorder: RecordingProvider {
    var mixPath: URL?
    var appPath: URL?
    var micPath: URL?
    var startCalled = false
    var stopCalled = false

    /// Args captured from the last `start(...)` so tests can pin that `WatchLoop`
    /// threads them through (appPID, noMic, micDeviceUID) instead of only checking
    /// `startCalled`. Defaults are deliberately "impossible" values so an unset or
    /// dropped argument fails an equality assertion rather than passing silently.
    var capturedAppPID: pid_t = -1
    var capturedNoMic = false
    var capturedMicDeviceUID: String?

    /// Per-channel level overrides for asymmetric-silence tests. Both default to -120
    /// (silence) so existing tests that don't touch these see the same behavior as
    /// the protocol's default implementations.
    var micLevelDBFS: Double = -120
    var appLevelDBFS: Double = -120

    func start(appPID: pid_t, noMic: Bool, micDeviceUID: String?, debugLogging _: Bool) {
        startCalled = true
        capturedAppPID = appPID
        capturedNoMic = noMic
        capturedMicDeviceUID = micDeviceUID
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
            recordingStart: ProcessInfo.processInfo.systemUptime,
        )
    }
}

/// Mock diarization that returns pre-set segments. Set `throwOnPathSuffix`
/// to simulate per-track failure (e.g. silent mic on a Mac mini host) —
/// the run() call throws when the audio path ends with that string.
/// `@unchecked Sendable` because tests configure mutable state before
/// exercising the diarizer; XCTest serialises per class.
final class MockDiarization: DiarizationProvider, @unchecked Sendable {
    var isAvailable: Bool = true
    var mode: DiarizerMode = .offline
    var runCount = 0
    /// The `numSpeakers` value passed to each `run` call, in order — lets tests
    /// assert how the speaker count is threaded (e.g. a naming-dialog re-run).
    var receivedNumSpeakers: [Int?] = []
    var throwOnPathSuffix: String?
    var resultToReturn: DiarizationResult?

    func run(audioPath: URL, numSpeakers: Int?, meetingTitle _: String) throws -> DiarizationResult {
        runCount += 1
        receivedNumSpeakers.append(numSpeakers)
        if let suffix = throwOnPathSuffix, audioPath.lastPathComponent.hasSuffix(suffix) {
            throw NSError(
                domain: "MockDiarization", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "mock diarizer threw on \(audioPath.lastPathComponent)"],
            )
        }
        if let result = resultToReturn {
            return result
        }
        return DiarizationResult(
            segments: [
                .init(start: 0, end: 5, speaker: "SPEAKER_00"),
                .init(start: 5, end: 10, speaker: "SPEAKER_01"),
            ],
            speakingTimes: ["SPEAKER_00": 5.0, "SPEAKER_01": 5.0],
            autoNames: [:],
            embeddings: nil,
        )
    }
}

/// Mock protocol generator that captures the transcript instead of calling Claude CLI.
class MockProtocolGen: ProtocolGenerating {
    var generateCalled = false
    var capturedTranscript: String?
    var capturedTitle: String?
    // swiftlint:disable:next discouraged_optional_boolean
    var capturedDiarized: Bool?
    var shouldThrow = false

    func generate(transcript: String, title: String, diarized: Bool) throws -> String {
        generateCalled = true
        capturedTranscript = transcript
        capturedTitle = title
        capturedDiarized = diarized
        if shouldThrow {
            throw NSError(
                domain: "MockProtocolGen",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Mock protocol error"],
            )
        }
        return """
        # Meeting Protocol - \(title)
        **Date:** 2026-03-06

        ---

        ## Summary
        Test protocol generated by mock.
        """
    }
}

/// Mock transcription engine for pipeline tests.
@MainActor
class MockEngine: TranscribingEngine {
    var modelState: EngineModelState = .loaded
    var downloadProgress: Double = 1.0
    var transcriptionProgress: Double = 1.0
    var segmentsToReturn: [TimestampedSegment] = []
    var transcribeCallCount = 0
    var shouldThrow = false

    func loadModel() {
        modelState = .loaded
    }

    func transcribeSegments(audioPath _: URL) throws -> [TimestampedSegment] {
        transcribeCallCount += 1
        if shouldThrow {
            throw NSError(domain: "MockEngine", code: 1, userInfo: [NSLocalizedDescriptionKey: "Mock transcription error"])
        }
        return segmentsToReturn
    }
}

/// In-memory `LiveSpeakerMatching` fake. Returns canned names by call
/// order (`canned[index % canned.count]`); empty `canned` means every
/// call resolves to `nil` (channel-default fallback path). Lives here
/// alongside `MockEngine` / `MockDiarization` / `MockProtocolGen` so
/// every live-transcription test reaches for the same fixture.
actor FakeLiveSpeakerMatcher: LiveSpeakerMatching {
    private let canned: [String]
    private var index = 0

    init(canned: [String] = []) {
        self.canned = canned
    }

    /// Convenience: keyed by channel name for readability at call sites,
    /// flattened into a stable order (mic → app) for deterministic
    /// playback.
    init(canned: [String: String]) {
        self.canned = [canned["mic"], canned["app"]].compactMap(\.self)
    }

    // swiftlint:disable:next unneeded_throws_rethrows async_without_await
    func prepare() async throws {} // protocol conformance — async/throws matches `LiveSpeakerMatching`

    // swiftlint:disable:next async_without_await
    func match(audio _: [Float]) async -> String? { // protocol conformance — `async` matches `LiveSpeakerMatching`
        guard !canned.isEmpty else { return nil }
        let name = canned[index % canned.count]
        index += 1
        return name
    }
}

// MARK: - Test Audio Fixture

/// Create a minimal valid 16kHz Float32 mono WAV (0.5s silence).
/// Uses UUID in filename to avoid collisions across concurrent tests.
func createTestAudioFile(in dir: URL) throws -> URL {
    let audioPath = dir.appendingPathComponent("test_audio_\(UUID().uuidString).wav")
    var header = Data(count: 44)
    header[0] = 0x52; header[1] = 0x49; header[2] = 0x46; header[3] = 0x46 // RIFF
    let fileSize = UInt32(44 + 32000 - 8)
    header.replaceSubrange(4 ..< 8, with: withUnsafeBytes(of: fileSize.littleEndian) { Data($0) })
    header[8] = 0x57; header[9] = 0x41; header[10] = 0x56; header[11] = 0x45 // WAVE
    header[12] = 0x66; header[13] = 0x6D; header[14] = 0x74; header[15] = 0x20 // fmt
    header.replaceSubrange(16 ..< 20, with: withUnsafeBytes(of: UInt32(16).littleEndian) { Data($0) })
    header.replaceSubrange(20 ..< 22, with: withUnsafeBytes(of: UInt16(3).littleEndian) { Data($0) }) // Float
    header.replaceSubrange(22 ..< 24, with: withUnsafeBytes(of: UInt16(1).littleEndian) { Data($0) }) // mono
    header.replaceSubrange(24 ..< 28, with: withUnsafeBytes(of: UInt32(16000).littleEndian) { Data($0) }) // 16kHz
    header.replaceSubrange(28 ..< 32, with: withUnsafeBytes(of: UInt32(64000).littleEndian) { Data($0) }) // byte rate
    header.replaceSubrange(32 ..< 34, with: withUnsafeBytes(of: UInt16(4).littleEndian) { Data($0) }) // block align
    header.replaceSubrange(34 ..< 36, with: withUnsafeBytes(of: UInt16(32).littleEndian) { Data($0) }) // bits
    header[36] = 0x64; header[37] = 0x61; header[38] = 0x74; header[39] = 0x61 // data
    header.replaceSubrange(40 ..< 44, with: withUnsafeBytes(of: UInt32(32000).littleEndian) { Data($0) })
    var data = header
    data.append(Data(repeating: 0, count: 32000))
    try data.write(to: audioPath)
    return audioPath
}

/// Write interleaved Float32 PCM as a raw `.tmp` blob (no header) — the format
/// the CATap IOProc emits and `DualSourceRecorder.buildRecording` reads back.
/// The headerless inverse of `createTestAudioFile` (which writes a WAV).
func writeRawFloat32(_ samples: [Float], to url: URL) throws {
    let data = samples.withUnsafeBufferPointer { Data(buffer: $0) }
    try data.write(to: url)
}

// MARK: - EOU streaming mock

/// Minimal `EouStreamingAsrManaging` double for the live-transcription
/// controller/coordinator tests: it produces no captions and loads no CoreML.
/// Construct with `loadError` to make `loadModels()` throw — the path the
/// English-streaming fallback (re-transcribe / no captions) hinges on. Lives
/// here (not in a single test file) so both the coordinator and controller
/// suites reach for the same fixture; `EouStreamingCaptionSessionTests` keeps
/// its own richer scripted mock.
actor MockEouManager: EouStreamingAsrManaging {
    private(set) var loadModelsCount = 0
    private let loadError: (any Error)?

    init(loadError: (any Error)? = nil) {
        self.loadError = loadError
    }

    func loadModels() throws {
        loadModelsCount += 1
        if let loadError { throw loadError }
    }

    // swiftlint:disable:next unneeded_throws_rethrows
    func appendAudio(_: AVAudioPCMBuffer) throws {}
    // swiftlint:disable:next async_without_await
    func processBufferedAudio() async {}
    // swiftlint:disable:next async_without_await
    func finish() async -> String {
        ""
    }

    // swiftlint:disable:next async_without_await
    func reset() async {}
    func setPartialCallback(_: @Sendable (String) -> Void) {}
    func setEouCallback(_: @Sendable (String) -> Void) {}
    func getEouTimestampsMs() -> [Int] {
        []
    }
}
