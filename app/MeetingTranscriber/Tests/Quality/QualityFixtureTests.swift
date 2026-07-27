import AVFoundation
@testable import MeetingTranscriber
import XCTest

/// Structural guards for the WER/DER fixtures and their ground-truth sidecars.
///
/// Unlike the WER/DER classes these need no models, so they run in every
/// `swift test` rather than behind `RUN_QUALITY_TESTS=1`. Their job is to catch
/// a fixture that was regenerated or hand-edited into something that no longer
/// measures what it was added to measure, before the expensive lane spends
/// three quarters of an hour producing numbers nobody can interpret.
///
/// The format invariants run over EVERY fixture. The two generators each
/// enforce their own output, but nothing re-checks a committed sidecar, and the
/// one cross-check neither generator can make is whether the WAV beside a truth
/// file is still the audio that truth file describes.
final class QualityFixtureTests: XCTestCase {
    /// Every committed quality fixture, synthetic and real.
    private static let allFixtures = [
        "two_speakers_de",
        "three_speakers_de",
        realFixture,
    ]

    /// The excerpt of a genuine recorded meeting. Singled out because the
    /// property it was added for, overlapping speech, is exactly what the
    /// synthetic fixtures lack.
    private static let realFixture = "four_speakers_en_ami"

    /// Overlapping speech as a fraction of the excerpt. The committed window
    /// sits at 0.31; the bound is the point below which the fixture stops being
    /// meaningfully harder than the synthetic ones.
    private static let minOverlapFraction = 0.15

    // MARK: - Invariants every fixture must hold

    func test_turns_lieWithinTheExcerptAndAreOrdered() throws {
        for name in Self.allFixtures {
            let truth = try GroundTruth.load(named: name)
            XCTAssertFalse(truth.turns.isEmpty, name)
            for turn in truth.turns {
                XCTAssertLessThan(turn.start, turn.end, "\(name): empty or inverted turn \(turn)")
                XCTAssertGreaterThanOrEqual(turn.start, 0, name)
                // Tolerance because both generators round timings to 6 decimals
                // independently of the duration: `three_speakers_de` has a final
                // turn ending 1 µs past its own declared duration. The assertion
                // is about turns not running off the end of the audio, and a
                // microsecond is four orders of magnitude below anything that
                // could affect a metric.
                XCTAssertLessThanOrEqual(turn.end, truth.duration + 0.001, name)
                XCTAssertFalse(turn.text.isEmpty, "\(name): turn with no transcript \(turn)")
            }
            XCTAssertEqual(
                truth.turns.map(\.start),
                truth.turns.map(\.start).sorted(),
                "\(name): turns must be in chronological order",
            )
        }
    }

    func test_referenceText_isTheConcatenationOfTurns() throws {
        for name in Self.allFixtures {
            let truth = try GroundTruth.load(named: name)
            XCTAssertEqual(truth.text, truth.turns.map(\.text).joined(separator: " "), name)
        }
    }

    /// The annotations the real fixture derives from escape apostrophes as
    /// `&#39;`. Left encoded, every contraction becomes a junk token and
    /// inflates WER against engines that transcribe them correctly.
    func test_referenceText_hasNoUndecodedEntities() throws {
        for name in Self.allFixtures {
            let truth = try GroundTruth.load(named: name)
            XCTAssertFalse(truth.text.contains("&#"), "\(name): undecoded XML entity")
        }
    }

    /// Catches the failure mode a malformed regeneration produces: a truth file
    /// describing a different stretch of audio than the WAV beside it. The
    /// timings would still look plausible in isolation while every DER number
    /// derived from them was meaningless.
    func test_audio_matchesTheDeclaredFormatAndLength() throws {
        for name in Self.allFixtures {
            let truth = try GroundTruth.load(named: name)
            let file = try AVAudioFile(forReading: truth.audioURL)
            XCTAssertEqual(file.fileFormat.sampleRate, Double(truth.sampleRate), name)
            XCTAssertEqual(file.fileFormat.channelCount, 1, name)

            let seconds = Double(file.length) / file.fileFormat.sampleRate
            XCTAssertEqual(
                seconds,
                truth.duration,
                accuracy: 0.05,
                "\(name): audio length disagrees with truth",
            )
        }
    }

    // MARK: - What separates the real fixture from the synthetic ones

    func test_realFixture_describesFourDistinctSpeakers() throws {
        let truth = try GroundTruth.load(named: Self.realFixture)
        XCTAssertEqual(Set(truth.turns.map(\.speaker)).count, 4)
    }

    func test_realFixture_containsSubstantialOverlappingSpeech() throws {
        let truth = try GroundTruth.load(named: Self.realFixture)
        let overlap = Self.overlappingSeconds(truth.turns)
        XCTAssertGreaterThan(
            overlap / truth.duration,
            Self.minOverlapFraction,
            "only \(overlap)s of \(truth.duration)s overlap — the fixture no longer "
                + "exercises simultaneous speakers, which is why it exists",
        )
    }

    /// The contrast that justifies the real fixture, and the proof that the
    /// overlap assertion above can actually fail: the synthetic fixtures are
    /// built by concatenating rendered speech with a second of silence between
    /// turns, so their overlap is exactly zero however many speakers they hold.
    ///
    /// Note what this does NOT imply. Making `DERCalculator` overlap-aware
    /// still moved one blessed synthetic row, because the metric degenerates
    /// only when the HYPOTHESIS is overlap-free too, and Sortformer reports
    /// 0.48 s of simultaneous speakers on `three_speakers_de` where the
    /// reference has one. That is a real false alarm the old metric discarded.
    func test_syntheticFixtures_containNoOverlapAtAll() throws {
        for name in ["two_speakers_de", "three_speakers_de"] {
            let truth = try GroundTruth.load(named: name)
            XCTAssertEqual(Self.overlappingSeconds(truth.turns), 0, accuracy: 0.001, name)
        }
    }

    /// The excerpt is third-party material redistributed under CC BY 4.0, so
    /// the truth file has to say what it is. ATTRIBUTION.md carries the
    /// human-facing credit; this keeps the machine-readable half from being
    /// dropped by a regeneration without anyone noticing.
    func test_realFixture_recordsItsProvenance() throws {
        let source = try XCTUnwrap(GroundTruth.load(named: Self.realFixture).source)
        XCTAssertTrue(source.contains("AMI Meeting Corpus"), source)
        XCTAssertTrue(source.contains("CC BY 4.0"), source)
    }

    // MARK: - Helpers

    /// Total wall-clock seconds during which two or more turns are active,
    /// counted once regardless of how many speakers overlap there. Mirrors the
    /// sweep in `scripts/lib/ami_fixture_truth.py`, so the overlap figure the
    /// generator prints while a window is being chosen is the one enforced here.
    private static func overlappingSeconds(_ turns: [GroundTruth.Turn]) -> Double {
        // Sweep line over turn boundaries. Ends sort before starts at equal
        // times so two turns that merely touch don't register as overlapping.
        struct Edge {
            let time: Double
            let delta: Int
        }
        var edges: [Edge] = []
        for turn in turns {
            edges.append(Edge(time: turn.start, delta: 1))
            edges.append(Edge(time: turn.end, delta: -1))
        }
        edges.sort { lhs, rhs in
            lhs.time == rhs.time ? lhs.delta < rhs.delta : lhs.time < rhs.time
        }

        var active = 0
        var total = 0.0
        var since = 0.0
        for edge in edges {
            if active >= 2 {
                total += edge.time - since
            }
            active += edge.delta
            since = edge.time
        }
        return total
    }
}
