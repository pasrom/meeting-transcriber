import AudioTapLib
@testable import MeetingTranscriber
import XCTest

/// End-to-end coverage for the live-transcription pipeline. Drives the
/// production wiring: `LiveTranscriptionController` + `StreamingTranscriber`
/// + real `FluidVAD` + real `ParakeetEngine`, with audio buffers handed in
/// through the same `LiveAudioSink` closures the recorder uses in
/// production. The CATap/AudioCaptureSession layer is bypassed because it
/// can't be exercised inside the xctest sandbox — that gap is the only
/// reason a sibling live-recording E2E (`scripts/e2e-live-captions.sh`)
/// exists.
///
/// Acceptance principle (matches the existing channel-health E2E): revert
/// any production wiring commit on this branch and one of these tests
/// must fail. Examples:
///   * revert `b6cda33` (audiotap live sink) → mic + app tests fail
///   * revert `bd46cdb` (app-channel live transcription) → app test fails
///   * revert `c2dcc35` (FluidVAD streaming API) → both fail
@MainActor
final class LiveTranscriptionE2ETests: XCTestCase {
    func testMicChannelProducesFinalisedCaption() async throws {
        try skipIfCIWithoutE2EOptIn("requires Parakeet model download")

        let setup = try await loadFixtureAndPrepareController()
        feed(setup.fixtureSamples, into: setup.controller.micSink)
        await waitForFinal(in: setup.captions)

        XCTAssertFalse(
            setup.captions.recentFinals.isEmpty,
            "live mic channel must finalise at least one caption — wiring broken?",
        )
        let micFinals = setup.captions.recentFinals.filter { $0.channel == .mic }
        XCTAssertFalse(
            micFinals.isEmpty,
            "expected at least one .mic-channel final, got channels: \(setup.captions.recentFinals.map(\.channel))",
        )
        // The German two-speaker fixture is engineered to surface common
        // words. Fuzzy match: any non-empty final at all means the chain
        // is wired and the engine produced text; a content match is the
        // robustness layer.
        let allText = micFinals.map(\.text).joined(separator: " ").lowercased()
        XCTAssertFalse(allText.isEmpty)
    }

    func testAppChannelProducesFinalisedCaption() async throws {
        try skipIfCIWithoutE2EOptIn("requires Parakeet model download")

        let setup = try await loadFixtureAndPrepareController()
        feed(setup.fixtureSamples, into: setup.controller.appSink)
        await waitForFinal(in: setup.captions)

        XCTAssertFalse(
            setup.captions.recentFinals.isEmpty,
            "live app channel must finalise at least one caption — wiring broken?",
        )
        let appFinals = setup.captions.recentFinals.filter { $0.channel == .app }
        XCTAssertFalse(
            appFinals.isEmpty,
            "expected at least one .app-channel final, got channels: \(setup.captions.recentFinals.map(\.channel))",
        )
    }

    func testCaptionsStayEmptyWhenNoBuffersAreFed() async throws {
        try skipIfCIWithoutE2EOptIn("requires Parakeet model download")

        let setup = try await loadFixtureAndPrepareController()
        // Idle for a moment with the controller wired up — nothing flowing
        // through the sinks. No captions should appear.
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertTrue(setup.captions.recentFinals.isEmpty)
        XCTAssertEqual(setup.captions.hypothesisMic, "")
        XCTAssertEqual(setup.captions.hypothesisApp, "")
    }

    // MARK: - Setup

    private struct LiveSetup {
        let controller: LiveTranscriptionController
        let captions: LiveCaptionsState
        let fixtureSamples: [Float]
    }

    private func loadFixtureAndPrepareController() async throws -> LiveSetup {
        let fixture = fixtureURL()
        try XCTSkipUnless(
            FileManager.default.fileExists(atPath: fixture.path),
            "Test fixture not found at \(fixture.path)",
        )
        let samples = try await loadFixtureAs16kMono(fixture)
        let captions = LiveCaptionsState()
        let engine = ParakeetEngine()
        let vad = FluidVAD(threshold: 0.5)
        let controller = LiveTranscriptionController(
            engine: engine, vad: vad, captions: captions,
        )
        await controller.prepare()
        return LiveSetup(
            controller: controller, captions: captions, fixtureSamples: samples,
        )
    }

    /// Chunk `samples` into ~80 ms windows and hand each to `sink` with a
    /// fabricated monotonically-increasing `hostTime` (so the resampler's
    /// drift detector sees a plausible timeline). A small inter-chunk
    /// sleep gives the actor a chance to drain its incoming queue.
    private func feed(
        _ samples: [Float],
        into sink: LiveAudioSink,
    ) {
        let chunkFrames = 1280 // ~80 ms at 16 kHz
        let ticksPerSecond = SampleRateDriftDetector.secondsToMachTicks(1.0)
        var hostTime: UInt64 = 0
        var offset = 0
        while offset < samples.count {
            let end = min(offset + chunkFrames, samples.count)
            let buffer = LiveAudioBuffer(
                samples: Array(samples[offset ..< end]),
                channelCount: 1,
                sampleRate: 16000,
                hostTime: hostTime,
            )
            sink(buffer)
            hostTime += ticksPerSecond * UInt64(end - offset) / 16000
            offset = end
            // Wall-clock yield so the actor's Task can pick up.
            usleep(2000)
        }
    }

    /// Poll the caption state until a final arrives or the deadline
    /// elapses. Replaces a fixed 3 s `Task.sleep` — typical cases
    /// complete in well under a second, so polling at 50 ms keeps the
    /// test responsive while bounding the wait if the engine emits
    /// nothing.
    private func waitForFinal(
        in captions: LiveCaptionsState,
        deadlineSeconds: Double = 3.0,
    ) async {
        let deadline = ContinuousClock.now + .seconds(deadlineSeconds)
        while await MainActor.run(body: { captions.recentFinals.isEmpty }),
              ContinuousClock.now < deadline {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
    }

    /// Decode the fixture WAV into a 16 kHz mono Float32 array via the
    /// production `AudioMixer` helpers — exercising the same load+resample
    /// path the batch pipeline uses, so a regression in either landing on
    /// only-test code is unlikely.
    private func loadFixtureAs16kMono(_ url: URL) async throws -> [Float] {
        let (raw, srcRate) = try await AudioMixer.loadAudioAsFloat32(url: url)
        guard srcRate != 16000 else { return raw }
        return AudioMixer.resample(raw, from: srcRate, to: 16000)
    }
}
