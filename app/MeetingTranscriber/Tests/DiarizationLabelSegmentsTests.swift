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
}
