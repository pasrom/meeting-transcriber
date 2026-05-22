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
/// Runs in regular CI (no `E2E_ENABLED` gate) so codecov sees the
/// `StreamingTranscriber` + `LiveTranscriptionController` + engine
/// streaming paths. The Parakeet model is already preloaded by
/// `ModelPreloadTests`, so the additional wall-clock is just the
/// fixture playback (~10 s end-to-end).
///
/// Acceptance principle (matches the existing channel-health E2E): revert
/// any production wiring commit on this branch and one of these tests
/// must fail. Examples:
///   * revert `b6cda33` (audiotap live sink) → mic + app tests fail
///   * revert `bd46cdb` (app-channel live transcription) → app test fails
///   * revert `c2dcc35` (FluidVAD streaming API) → both fail
@MainActor
final class LiveTranscriptionE2ETests: XCTestCase {
    /// Combined coverage for the mic channel, the app channel, and the
    /// idle (no-buffers) precondition. Kept as a single test method
    /// because `swift test --parallel` runs each method in its own xctest
    /// worker process, and two parallel workers freshly loading the
    /// Parakeet CoreML model race on the `~/Library/Caches/.../e5rt`
    /// bundle cache rename → `Directory not empty` from the BNNS encoder
    /// bundle write → inference silently broken for the duration of the
    /// run. Folding all three scenarios into one method means a single
    /// worker loads Parakeet once and the race can't happen.
    ///
    /// Acceptance principle (matches the channel-health E2E): revert any
    /// production wiring commit on this branch and one of the assertions
    /// here must fail. Examples:
    ///   * revert `b6cda33` (audiotap live sink) → mic + app paths fail
    ///   * revert `bd46cdb` (app-channel live transcription) → app path fails
    ///   * revert `c2dcc35` (FluidVAD streaming API) → both fail
    func testLivePipelineProducesFinalisedCaptionsAcrossChannels() async throws {
        let setup = try await loadFixtureAndPrepareController()

        // (1) Idle precondition: with the controller wired up but no
        // buffers fed, nothing should appear in the caption state. Catches
        // a regression where the controller pre-emits text on prepare()
        // or an idle tick causes a spurious emission.
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertTrue(setup.captions.recentFinals.isEmpty, "idle controller must not emit captions")
        XCTAssertEqual(setup.captions.hypothesisMic, "")
        XCTAssertEqual(setup.captions.hypothesisApp, "")

        // (2) Mic channel: feed the fixture into the mic sink, wait for
        // a final on the .mic channel.
        feed(setup.fixtureSamples, into: setup.controller.micSink)
        await waitForFinal(in: setup.captions, channel: .mic)

        let micFinals = setup.captions.recentFinals.filter { $0.channel == .mic }
        XCTAssertFalse(
            micFinals.isEmpty,
            "expected at least one .mic-channel final, got channels: \(setup.captions.recentFinals.map(\.channel))",
        )
        // The German two-speaker fixture is engineered to surface common
        // words. Fuzzy match: any non-empty final at all means the chain
        // is wired and the engine produced text; a content match is the
        // robustness layer.
        let micText = micFinals.map(\.text).joined(separator: " ").lowercased()
        XCTAssertFalse(micText.isEmpty)

        // (3) App channel: feed the same fixture into the app sink, wait
        // for a final on the .app channel. Re-uses the same engine + VAD
        // — same process, no parallel-load race.
        feed(setup.fixtureSamples, into: setup.controller.appSink)
        await waitForFinal(in: setup.captions, channel: .app)

        let appFinals = setup.captions.recentFinals.filter { $0.channel == .app }
        XCTAssertFalse(
            appFinals.isEmpty,
            "expected at least one .app-channel final, got channels: \(setup.captions.recentFinals.map(\.channel))",
        )
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

    /// Poll the caption state until a final on `channel` arrives or the
    /// deadline elapses. Replaces a fixed `Task.sleep` — typical cases
    /// complete in well under a second locally, so polling at 50 ms keeps
    /// the test responsive while bounding the wait if the engine emits
    /// nothing.
    ///
    /// Default deadline is 30 s because the macos-26 CI runner is a
    /// virtualised M1 with 3 CPU cores and no ANE — Parakeet inference
    /// on CPU is ~5× slower than local M-series hardware. Locally the
    /// poll usually returns inside 1 s on the first final, so the
    /// generous deadline is "safety net for slow CI", not "expected
    /// wall-clock budget".
    ///
    /// The `channel` filter lets a single test wait for a mic-channel
    /// final and then a separate app-channel final — without the filter,
    /// the second `waitForFinal` would return immediately on the lingering
    /// mic-channel entries from step (2).
    private func waitForFinal(
        in captions: LiveCaptionsState,
        channel: LiveCaptionChannel,
        deadlineSeconds: Double = 30.0,
    ) async {
        let deadline = ContinuousClock.now + .seconds(deadlineSeconds)
        while await MainActor.run(body: {
            !captions.recentFinals.contains { $0.channel == channel }
        }), ContinuousClock.now < deadline {
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
