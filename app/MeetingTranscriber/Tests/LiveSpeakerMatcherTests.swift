@testable import MeetingTranscriber
import XCTest

/// Unit tests for `LiveSpeakerMatcher`'s fallback + sentinel-detection
/// semantics. The CoreML embedding extraction itself is exercised by
/// `LiveTranscriptionE2ETests` (real audio fixture) — these tests pin the
/// behaviour around an *empty* speaker DB and the SpeakerMatcher
/// integration, which doesn't need a real model load.
@MainActor
final class LiveSpeakerMatcherTests: XCTestCase {
    /// With no enrolled speakers in `speakers.json`, every match attempt
    /// must return nil so the controller falls back to the channel-default
    /// label. Catches a regression where the sentinel-name detection flips
    /// (e.g. returning `__live__` to the caller) or where the matcher
    /// returns a hallucinated name from an empty DB.
    func testMatchReturnsNilWithEmptyDB() async {
        let tempDB = FileManager.default.temporaryDirectory
            .appendingPathComponent("test-empty-speakers-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: tempDB) }
        // Empty DB: a fresh SpeakerMatcher with no entries falls through
        // every threshold check.
        let sm = SpeakerMatcher(dbPath: tempDB)
        let matcher = LiveSpeakerMatcher(speakerMatcher: sm)

        // `match` calls into the actor, which lazy-loads the WeSpeaker
        // model. Pre-warm fails fast in xctest's sandbox if the model
        // isn't already cached — that's fine, the matcher swallows the
        // error and returns nil.
        let name = await matcher.match(audio: [Float](repeating: 0.0, count: 16000))
        XCTAssertNil(
            name,
            "empty speaker DB must resolve to nil (channel-default fallback)",
        )
    }

    /// Pre-warm errors must not propagate — the controller relies on
    /// `match` returning nil on any model-load failure so a transient
    /// network blip during the WeSpeaker download doesn't break captions.
    func testMatchReturnsNilWhenAudioIsEmpty() async {
        let tempDB = FileManager.default.temporaryDirectory
            .appendingPathComponent("test-empty-audio-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: tempDB) }
        let matcher = LiveSpeakerMatcher(speakerMatcher: SpeakerMatcher(dbPath: tempDB))
        let name = await matcher.match(audio: [])
        XCTAssertNil(name, "empty audio must resolve to nil")
    }
}
