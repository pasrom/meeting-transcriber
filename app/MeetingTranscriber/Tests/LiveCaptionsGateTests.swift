@testable import MeetingTranscriber
import XCTest

/// Truth table for `LiveCaptionsGate` — the shared decision logic for whether
/// live captions run and which per-channel streaming backend they use. Pure +
/// value-typed, so the full input grid is enumerable here without constructing
/// the coordinator/controller actors.
///
/// **Master toggle (`liveEnabled`) gates everything.** When on, the streaming
/// backend is chosen from the active engine's EXPLICITLY configured language:
///   * `de` → `.germanStreaming` (Nemotron multilingual streaming session)
///   * `en` → `.englishStreaming` (Parakeet EOU streaming session)
///   * anything else (auto-detect / unsupported) → `.reTranscribe` if the
///     engine supports the in-memory path, else `.none`.
///
/// The two streaming backends bypass the active engine entirely, so they are
/// available even when `engineSupportsLive` is false. Auto-detect deliberately
/// does NOT route to a streaming model (the spoken language isn't statically
/// known) — it falls back to the engine-driven re-transcribe path.
final class LiveCaptionsGateTests: XCTestCase {
    func testLiveDisabledYieldsNoneRegardlessOfLanguage() {
        for lang in ["de", "en", nil, "fr"] {
            XCTAssertEqual(
                LiveCaptionsGate.strategy(liveEnabled: false, engineLanguage: lang, engineSupportsLive: true),
                .none, "master off must be .none (lang=\(lang ?? "nil"))",
            )
        }
    }

    func testGermanLanguageYieldsGermanStreaming() {
        XCTAssertEqual(
            LiveCaptionsGate.strategy(liveEnabled: true, engineLanguage: "de", engineSupportsLive: true),
            .germanStreaming,
        )
    }

    func testEnglishLanguageYieldsEnglishStreaming() {
        XCTAssertEqual(
            LiveCaptionsGate.strategy(liveEnabled: true, engineLanguage: "en", engineSupportsLive: true),
            .englishStreaming,
        )
    }

    func testAutoDetectLanguageFallsBackToReTranscribe() {
        XCTAssertEqual(
            LiveCaptionsGate.strategy(liveEnabled: true, engineLanguage: nil, engineSupportsLive: true),
            .reTranscribe,
        )
    }

    func testAutoDetectWithUnsupportedEngineYieldsNone() {
        XCTAssertEqual(
            LiveCaptionsGate.strategy(liveEnabled: true, engineLanguage: nil, engineSupportsLive: false),
            .none,
        )
    }

    func testOtherLanguageFallsBackToReTranscribe() {
        XCTAssertEqual(
            LiveCaptionsGate.strategy(liveEnabled: true, engineLanguage: "fr", engineSupportsLive: true),
            .reTranscribe,
        )
    }

    // MARK: - captionsAvailable

    func testStreamingBackendsAvailableEvenWhenEngineUnsupported() {
        XCTAssertTrue(LiveCaptionsGate.captionsAvailable(
            liveEnabled: true, engineLanguage: "de", engineSupportsLive: false,
        ))
        XCTAssertTrue(LiveCaptionsGate.captionsAvailable(
            liveEnabled: true, engineLanguage: "en", engineSupportsLive: false,
        ))
    }

    func testReTranscribeAvailabilityRequiresEngineSupport() {
        XCTAssertTrue(LiveCaptionsGate.captionsAvailable(
            liveEnabled: true, engineLanguage: nil, engineSupportsLive: true,
        ))
        XCTAssertFalse(LiveCaptionsGate.captionsAvailable(
            liveEnabled: true, engineLanguage: nil, engineSupportsLive: false,
        ))
    }

    func testCaptionsUnavailableWhenLiveDisabled() {
        XCTAssertFalse(LiveCaptionsGate.captionsAvailable(
            liveEnabled: false, engineLanguage: "de", engineSupportsLive: true,
        ))
    }
}
