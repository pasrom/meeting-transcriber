@testable import MeetingTranscriber
import XCTest

final class GroundTruthTests: XCTestCase {
    func test_loadTwoSpeakersFixture_parsesTurnsAndText() throws {
        let truth = try GroundTruth.load(named: "two_speakers_de")
        XCTAssertEqual(truth.fixture, "two_speakers_de")
        XCTAssertEqual(truth.audio, "two_speakers_de.wav")
        XCTAssertEqual(truth.sampleRate, 16000)
        XCTAssertGreaterThan(truth.duration, 10.0)
        XCTAssertEqual(truth.turns.count, 4)
        XCTAssertEqual(truth.turns[0].speaker, "A")
        XCTAssertEqual(truth.turns[1].speaker, "B")
        XCTAssertEqual(truth.turns[2].speaker, "A")
        XCTAssertEqual(truth.turns[3].speaker, "B")
        // Each turn should have positive duration and start before its end.
        for turn in truth.turns {
            XCTAssertLessThan(turn.start, turn.end, "turn \(turn.speaker) start>=end")
        }
        // Concatenated text should be non-empty and contain at least one
        // expected German keyword from the script.
        XCTAssertTrue(truth.text.contains("Projekt") || truth.text.contains("Entwicklung"))
    }

    func test_loadThreeSpeakersFixture_parsesAllSpeakers() throws {
        let truth = try GroundTruth.load(named: "three_speakers_de")
        let speakers = Set(truth.turns.map(\.speaker))
        XCTAssertEqual(speakers, ["A", "B", "C"])
        XCTAssertEqual(truth.turns.count, 6)
    }

    func test_diarizationTurns_mapToDERCalculatorShape() throws {
        let truth = try GroundTruth.load(named: "two_speakers_de")
        let derTurns = truth.diarizationTurns
        XCTAssertEqual(derTurns.count, truth.turns.count)
        XCTAssertEqual(derTurns[0].speaker, "A")
        XCTAssertEqual(derTurns[0].start, truth.turns[0].start)
        XCTAssertEqual(derTurns[0].end, truth.turns[0].end)
    }

    func test_audioURL_pointsToExistingFile() throws {
        let truth = try GroundTruth.load(named: "two_speakers_de")
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: truth.audioURL.path),
            "Audio file not found at \(truth.audioURL.path)",
        )
    }

    func test_perfectHypothesis_yieldsZeroWERAndZeroDER() throws {
        // Sanity check: feeding the ground-truth back as the hypothesis
        // produces WER = 0 and DER = 0. Catches drift in calculator
        // semantics (e.g. accidental normalisation regressions).
        let truth = try GroundTruth.load(named: "two_speakers_de")
        let wer = WERCalculator.wer(reference: truth.text, hypothesis: truth.text)
        XCTAssertEqual(wer, 0.0, accuracy: 1e-9)
        let der = DERCalculator.der(
            reference: truth.diarizationTurns,
            hypothesis: truth.diarizationTurns,
        )
        XCTAssertEqual(der, 0.0, accuracy: 1e-9)
    }
}
