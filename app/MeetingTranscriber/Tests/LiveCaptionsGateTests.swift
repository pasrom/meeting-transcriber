@testable import MeetingTranscriber
import XCTest

/// Truth table for `LiveCaptionsGate` — the shared decision logic for whether
/// live captions run and which per-channel pipeline strategy they use. Pure +
/// value-typed, so the full 2×2×2 input grid is enumerable here without
/// constructing the coordinator/controller actors.
///
/// The three inputs:
///   * `liveEnabled` — the master live-captions toggle (gates everything).
///   * `englishStreaming` — the English low-latency opt-in (bypasses the
///     engine-support gate, because the EOU session is engine-independent).
///   * `engineSupportsLive` — whether the active engine implements the
///     in-memory `transcribeSamples` re-transcribe hook.
final class LiveCaptionsGateTests: XCTestCase {
    // MARK: - Live-enabled toggle gates everything

    func testLiveDisabledYieldsNoneRegardlessOfOtherInputs() {
        for english in [true, false] {
            for supports in [true, false] {
                let strategy = LiveCaptionsGate.strategy(
                    liveEnabled: false, englishStreaming: english, engineSupportsLive: supports,
                )
                XCTAssertEqual(
                    strategy, .none,
                    "master off must yield .none (english=\(english), supports=\(supports))",
                )
                XCTAssertFalse(LiveCaptionsGate.captionsAvailable(
                    liveEnabled: false, englishStreaming: english, engineSupportsLive: supports,
                ))
            }
        }
    }

    // MARK: - English streaming bypasses the engine-support gate

    func testEnglishStreamingOnYieldsEnglishStreamingEvenWhenEngineSupportsLive() {
        let strategy = LiveCaptionsGate.strategy(
            liveEnabled: true, englishStreaming: true, engineSupportsLive: true,
        )
        XCTAssertEqual(strategy, .englishStreaming)
    }

    func testEnglishStreamingOnYieldsEnglishStreamingEvenWhenEngineUnsupported() {
        // The key bypass: an engine without the re-transcribe hook (e.g. Qwen3)
        // still gets captions via the engine-independent EOU session.
        let strategy = LiveCaptionsGate.strategy(
            liveEnabled: true, englishStreaming: true, engineSupportsLive: false,
        )
        XCTAssertEqual(strategy, .englishStreaming)
        XCTAssertTrue(LiveCaptionsGate.captionsAvailable(
            liveEnabled: true, englishStreaming: true, engineSupportsLive: false,
        ), "english streaming makes captions available even for an unsupported engine")
    }

    // MARK: - Re-transcribe path requires engine support (unchanged behaviour)

    func testReTranscribeWhenStreamingOffAndEngineSupportsLive() {
        let strategy = LiveCaptionsGate.strategy(
            liveEnabled: true, englishStreaming: false, engineSupportsLive: true,
        )
        XCTAssertEqual(strategy, .reTranscribe)
    }

    func testNoneWhenStreamingOffAndEngineUnsupported() {
        // Today's behaviour: master on but neither the engine supports the
        // re-transcribe path nor is the English opt-in set → no captions.
        let strategy = LiveCaptionsGate.strategy(
            liveEnabled: true, englishStreaming: false, engineSupportsLive: false,
        )
        XCTAssertEqual(strategy, .none)
        XCTAssertFalse(LiveCaptionsGate.captionsAvailable(
            liveEnabled: true, englishStreaming: false, engineSupportsLive: false,
        ))
    }
}
