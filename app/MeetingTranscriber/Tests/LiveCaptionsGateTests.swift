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
///   * any other trained explicit language → `.nemotronStreaming` (Nemotron multilingual;
///     FluidAudio auto-selects the Latin or full multilingual model variant)
///   * auto-detect (nil) or an untrained language → `.reTranscribe` if the engine supports the in-memory
///     path, else `.none`.
///
/// The two streaming backends bypass the active engine entirely, so they are
/// available even when `engineSupportsLive` is false. Auto-detect deliberately
/// does NOT route to a streaming model (the spoken language isn't statically
/// known) — it falls back to the engine-driven re-transcribe path.
final class LiveCaptionsGateTests: XCTestCase {
    func testLiveDisabledYieldsNoneRegardlessOfLanguage() {
        for lang in ["de", "en", "ru", "id", nil, "zh"] {
            XCTAssertEqual(
                LiveCaptionsGate.strategy(liveEnabled: false, engineLanguage: lang, engineSupportsLive: true, cloudTranscriptionEnabled: false),
                .none, "live disabled must be .none (lang=\(lang ?? "nil"))",
            )
        }
    }

    func testExplicitNonEnglishLanguagesYieldNemotronStreaming() {
        // Latin-script (latin model) and non-Latin (multilingual model) both
        // route to Nemotron; FluidAudio picks the variant from the language code.
        for lang in ["de", "es", "fr", "it", "pt", "pt-PT", "nl", "ru", "zh", "ja", "no", "PT_br"] {
            XCTAssertEqual(
                LiveCaptionsGate.strategy(liveEnabled: true, engineLanguage: lang, engineSupportsLive: true, cloudTranscriptionEnabled: false),
                .nemotronStreaming, "\(lang) must route to Nemotron",
            )
        }
    }

    func testEnglishLanguageYieldsEnglishStreaming() {
        for lang in ["en", "en-US", "en-GB", "EN_us"] {
            XCTAssertEqual(
                LiveCaptionsGate.strategy(liveEnabled: true, engineLanguage: lang, engineSupportsLive: false, cloudTranscriptionEnabled: false),
                .englishStreaming, "\(lang) uses the English-optimized EOU path",
            )
        }
    }

    func testUntrainedExplicitLanguageFallsBackOnlyWhenEngineSupportsLive() {
        for lang in ["id", "id-ID", "ms", "pt-AO"] {
            XCTAssertEqual(
                LiveCaptionsGate.strategy(liveEnabled: true, engineLanguage: lang, engineSupportsLive: true, cloudTranscriptionEnabled: false),
                .reTranscribe, lang,
            )
            XCTAssertEqual(
                LiveCaptionsGate.strategy(liveEnabled: true, engineLanguage: lang, engineSupportsLive: false, cloudTranscriptionEnabled: false),
                .none, lang,
            )
        }
    }

    func testAutoDetectLanguageFallsBackToReTranscribe() {
        XCTAssertEqual(
            LiveCaptionsGate.strategy(liveEnabled: true, engineLanguage: nil, engineSupportsLive: true, cloudTranscriptionEnabled: false),
            .reTranscribe,
        )
    }

    func testAutoDetectWithUnsupportedEngineYieldsNone() {
        XCTAssertEqual(
            LiveCaptionsGate.strategy(liveEnabled: true, engineLanguage: nil, engineSupportsLive: false, cloudTranscriptionEnabled: false),
            .none,
        )
    }

    private func available(
        liveEnabled: Bool, engineLanguage: String?, engineSupportsLive: Bool, cloudTranscriptionEnabled: Bool,
    ) -> Bool {
        LiveCaptionsGate.strategy(
            liveEnabled: liveEnabled, engineLanguage: engineLanguage,
            engineSupportsLive: engineSupportsLive, cloudTranscriptionEnabled: cloudTranscriptionEnabled,
        ) != .none
    }

    // MARK: - Availability (any strategy but none)

    func testStreamingBackendsAvailableEvenWhenEngineUnsupported() {
        XCTAssertTrue(available(
            liveEnabled: true, engineLanguage: "de", engineSupportsLive: false, cloudTranscriptionEnabled: false,
        ))
        XCTAssertTrue(available(
            liveEnabled: true, engineLanguage: "en", engineSupportsLive: false, cloudTranscriptionEnabled: false,
        ))
    }

    func testReTranscribeAvailabilityRequiresEngineSupport() {
        XCTAssertTrue(available(
            liveEnabled: true, engineLanguage: nil, engineSupportsLive: true, cloudTranscriptionEnabled: false,
        ))
        XCTAssertFalse(available(
            liveEnabled: true, engineLanguage: nil, engineSupportsLive: false, cloudTranscriptionEnabled: false,
        ))
        XCTAssertTrue(available(
            liveEnabled: true, engineLanguage: "id-ID", engineSupportsLive: true, cloudTranscriptionEnabled: false,
        ))
        XCTAssertFalse(available(
            liveEnabled: true, engineLanguage: "id-ID", engineSupportsLive: false, cloudTranscriptionEnabled: false,
        ))
    }

    func testCaptionsUnavailableWhenLiveDisabled() {
        XCTAssertFalse(available(
            liveEnabled: false, engineLanguage: "de", engineSupportsLive: true, cloudTranscriptionEnabled: false,
        ))
    }

    // MARK: - Cloud transcription

    func testCloudOnTurnsEveryReTranscribeRouteOff() {
        for lang in [nil, "id", "pt-AO"] as [String?] {
            XCTAssertEqual(
                LiveCaptionsGate.strategy(liveEnabled: true, engineLanguage: lang, engineSupportsLive: true, cloudTranscriptionEnabled: true),
                .none, "\(lang ?? "auto"): re-transcribe would load the local model",
            )
        }
    }

    func testCloudOnKeepsTheStreamingBackends() {
        XCTAssertEqual(
            LiveCaptionsGate.strategy(liveEnabled: true, engineLanguage: "en", engineSupportsLive: true, cloudTranscriptionEnabled: true),
            .englishStreaming,
        )
        XCTAssertEqual(
            LiveCaptionsGate.strategy(liveEnabled: true, engineLanguage: "de", engineSupportsLive: true, cloudTranscriptionEnabled: true),
            .nemotronStreaming,
        )
    }

    func testOffForCloudOnlyWhereCloudIsWhatTurnsCaptionsOff() {
        XCTAssertTrue(LiveCaptionsGate.offForCloud(engineLanguage: nil, engineSupportsLive: true))
        XCTAssertTrue(LiveCaptionsGate.offForCloud(engineLanguage: "id", engineSupportsLive: true))
        XCTAssertFalse(LiveCaptionsGate.offForCloud(engineLanguage: "en", engineSupportsLive: true), "streams without the engine")
        XCTAssertFalse(LiveCaptionsGate.offForCloud(engineLanguage: nil, engineSupportsLive: false), "off with cloud off too")
    }
}
