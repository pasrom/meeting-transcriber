@testable import MeetingTranscriber
import XCTest

/// Truth table for `LiveCaptionsGate` — the shared decision logic for whether
/// live captions run and which per-channel streaming backend they use. Pure +
/// value-typed, so the full input grid is enumerable here without constructing
/// the coordinator/controller actors.
///
/// **Master toggle (`liveEnabled`) gates everything.** When on, the streaming
/// backend is chosen from the active engine's EXPLICITLY configured language:
///   * `en` → `.englishStreaming` (Parakeet EOU streaming, English-optimized)
///   * any other explicit language → `.nemotronStreaming` (Nemotron multilingual;
///     FluidAudio auto-selects the Latin or full multilingual model variant)
///   * auto-detect (nil) → `.reTranscribe` if the engine supports the in-memory
///     path, else `.none`.
///
/// The two streaming backends bypass the active engine entirely, so they are
/// available even when `engineSupportsLive` is false. Auto-detect deliberately
/// does NOT route to a streaming model (the spoken language isn't statically
/// known) — it falls back to the engine-driven re-transcribe path.
final class LiveCaptionsGateTests: XCTestCase {
    func testLiveDisabledYieldsNoneRegardlessOfLanguage() {
        for lang in ["de", "en", "ru", nil, "zh"] {
            XCTAssertEqual(
                LiveCaptionsGate.strategy(liveEnabled: false, engineLanguage: lang, engineSupportsLive: true),
                .none, "live disabled must be .none (lang=\(lang ?? "nil"))",
            )
        }
    }

    func testExplicitNonEnglishLanguagesYieldNemotronStreaming() {
        // Latin-script (latin model) and non-Latin (multilingual model) both
        // route to Nemotron; FluidAudio picks the variant from the language code.
        for lang in ["de", "es", "fr", "it", "pt", "nl", "ru", "zh", "ja"] {
            XCTAssertEqual(
                LiveCaptionsGate.strategy(liveEnabled: true, engineLanguage: lang, engineSupportsLive: true),
                .nemotronStreaming, "\(lang) must route to Nemotron",
            )
        }
    }

    func testEnglishLanguageYieldsEnglishStreaming() {
        XCTAssertEqual(
            LiveCaptionsGate.strategy(liveEnabled: true, engineLanguage: "en", engineSupportsLive: true),
            .englishStreaming, "English uses the English-optimized EOU path, not Nemotron",
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
