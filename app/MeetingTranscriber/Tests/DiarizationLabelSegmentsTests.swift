@testable import MeetingTranscriber
import XCTest

/// Unit tests for `DiarizationProcess.labelSegments`, the topology-dispatching
/// speaker-assignment entry point that unifies the three formerly-inline
/// assignment blocks in `PipelineQueue.diarize` (single-source / dual-track /
/// dual-track mic-fail app-only fallback).
final class DiarizationLabelSegmentsTests: XCTestCase {
    func testLabelSegmentsSingleAppliesAutoNames() {
        let segments = [
            TimestampedSegment(start: 0, end: 5, text: "Hello"),
            TimestampedSegment(start: 5, end: 10, text: "World"),
        ]
        let diarization = DiarizationResult(
            segments: [
                .init(start: 0, end: 5, speaker: "SPEAKER_0"),
                .init(start: 5, end: 10, speaker: "SPEAKER_1"),
            ],
            speakingTimes: ["SPEAKER_0": 5, "SPEAKER_1": 5],
            autoNames: [:],
            embeddings: nil,
        )
        let result = DiarizationProcess.labelSegments(
            .single(segments: segments, diarization: diarization),
            autoNames: ["SPEAKER_0": "Alice", "SPEAKER_1": "Bob"],
        )
        XCTAssertEqual(result.map(\.speaker), ["Alice", "Bob"])
    }

    func testLabelSegmentsDualTrackUnprefixesAndAssignsPerTrack() {
        // App track tagged "Remote", mic track tagged with micLabel "Me".
        let cached = [
            TimestampedSegment(start: 0, end: 5, text: "app line", speaker: "Remote"),
            TimestampedSegment(start: 5, end: 10, text: "mic line", speaker: "Me"),
        ]
        let app = DiarizationResult(
            segments: [.init(start: 0, end: 5, speaker: "S0")],
            speakingTimes: ["S0": 5], autoNames: [:], embeddings: nil,
        )
        let mic = DiarizationResult(
            segments: [.init(start: 5, end: 10, speaker: "S0")],
            speakingTimes: ["S0": 5], autoNames: [:], embeddings: nil,
        )
        // autoNames arrive R_/M_-prefixed (as mergeDualTrackDiarization produces).
        let result = DiarizationProcess.labelSegments(
            .dualTrack(cached: cached, micLabel: "Me", app: app, mic: mic),
            autoNames: ["R_S0": "Alice", "M_S0": "Bob"],
        )
        XCTAssertEqual(result.map(\.speaker), ["Alice", "Bob"])
        XCTAssertEqual(result.map(\.text), ["app line", "mic line"])
    }

    func testLabelSegmentsDualTrackAppOnlyKeepsRawMicLabel() {
        let cached = [
            TimestampedSegment(start: 0, end: 5, text: "app line", speaker: "Remote"),
            TimestampedSegment(start: 5, end: 10, text: "mic line", speaker: "Me"),
        ]
        // In the real mic-fail path diarize() passes the *unprefixed* app
        // diarization (`diarization = appDiarization`), so segment IDs and
        // autoNames keys are raw ("SPEAKER_0"), not R_-prefixed.
        let app = DiarizationResult(
            segments: [.init(start: 0, end: 5, speaker: "SPEAKER_0")],
            speakingTimes: ["SPEAKER_0": 5], autoNames: [:], embeddings: nil,
        )
        let result = DiarizationProcess.labelSegments(
            .dualTrackAppOnly(cached: cached, micLabel: "Me", app: app),
            autoNames: ["SPEAKER_0": "Alice"],
        )
        // App segments are assigned their matched name (the autoNames keys are
        // already unprefixed in this fallback, since `combined == appDiarization`).
        // Mic segments keep their raw micLabel (mic wasn't diarized).
        XCTAssertEqual(result.map(\.speaker), ["Alice", "Me"])
        XCTAssertEqual(result.map(\.text), ["app line", "mic line"])
    }

    func testLabelSegmentsDualTrackMicOnlyKeepsRawRemoteLabel() {
        // Mirror of the app-only fallback for the opposite failure: the app
        // (remote) track diarization failed (e.g. a silent remote side in a
        // solo meeting), so diarize() passes the *unprefixed* mic diarization
        // (`diarization = micDiarization`); autoNames keys are raw ("SPEAKER_0").
        let cached = [
            TimestampedSegment(start: 0, end: 5, text: "app line", speaker: "Remote"),
            TimestampedSegment(start: 5, end: 10, text: "mic line", speaker: "Me"),
        ]
        let mic = DiarizationResult(
            segments: [.init(start: 5, end: 10, speaker: "SPEAKER_0")],
            speakingTimes: ["SPEAKER_0": 5], autoNames: [:], embeddings: nil,
        )
        let result = DiarizationProcess.labelSegments(
            .dualTrackMicOnly(cached: cached, micLabel: "Me", mic: mic),
            autoNames: ["SPEAKER_0": "Bob"],
        )
        // Mic segments get their matched name; app segments keep their raw
        // "Remote" tag (the app track wasn't diarized).
        XCTAssertEqual(result.map(\.speaker), ["Remote", "Bob"])
        XCTAssertEqual(result.map(\.text), ["app line", "mic line"])
    }

    // MARK: - unprefixNames

    /// `unprefixNames` keeps only the keys belonging to the requested track and
    /// re-keys them to the raw diarizer id, silently excluding the other track
    /// and any unprefixed (single-source) key. Pins the parse side of the
    /// `SpeakerKey` boundary: the literal `R_`/`M_` prefixes must still be
    /// recognised, so this fails if the prefix strings ever change.
    func testUnprefixNamesFiltersAndRekeysByTrack() {
        let autoNames = ["R_SPEAKER_0": "Alice", "M_SPEAKER_1": "Bob", "SPEAKER_2": "Carol"]

        XCTAssertEqual(DiarizationProcess.unprefixNames(autoNames, track: .app), ["SPEAKER_0": "Alice"])
        XCTAssertEqual(DiarizationProcess.unprefixNames(autoNames, track: .mic), ["SPEAKER_1": "Bob"])
    }

    /// Producing (`mergeDualTrackDiarization`) then parsing (`unprefixNames`)
    /// round-trips each track's `autoNames` back to their raw ids, proving the
    /// prefix production and parsing agree byte-for-byte through `SpeakerKey`.
    func testMergeThenUnprefixNamesRoundTrips() {
        let appDiar = DiarizationResult(
            segments: [.init(start: 0, end: 5, speaker: "SPEAKER_0")],
            speakingTimes: ["SPEAKER_0": 5], autoNames: ["SPEAKER_0": "Alice"], embeddings: nil,
        )
        let micDiar = DiarizationResult(
            segments: [.init(start: 0, end: 3, speaker: "SPEAKER_0")],
            speakingTimes: ["SPEAKER_0": 3], autoNames: ["SPEAKER_0": "Bob"], embeddings: nil,
        )
        let merged = DiarizationProcess.mergeDualTrackDiarization(appDiarization: appDiar, micDiarization: micDiar)

        XCTAssertEqual(DiarizationProcess.unprefixNames(merged.autoNames, track: .app), ["SPEAKER_0": "Alice"])
        XCTAssertEqual(DiarizationProcess.unprefixNames(merged.autoNames, track: .mic), ["SPEAKER_0": "Bob"])
    }
}
