// Pure-logic tests for the LocalVQE selftest argument parsing — the decision
// AppLauncher uses to divert a launch into the bundle probe instead of the
// GUI. The probe itself runs only via scripts/localvqe-bundle-check.sh.
#if !APPSTORE
    @testable import MeetingTranscriber
    import XCTest

    final class LocalVQESelftestTests: XCTestCase {
        func testAbsentFlagMeansNormalLaunch() {
            XCTAssertNil(LocalVQESelftest.parse(arguments: ["/path/to/app"]))
            XCTAssertNil(LocalVQESelftest.parse(arguments: ["/path/to/app", "--auto-watch"]))
        }

        func testBareFlagRunsLinkOnlyProbe() {
            let mode = LocalVQESelftest.parse(arguments: ["/path/to/app", "--localvqe-selftest"])
            XCTAssertEqual(mode, .linkOnly)
        }

        func testFlagWithPathRunsModelProbe() {
            let mode = LocalVQESelftest.parse(
                arguments: ["/path/to/app", "--localvqe-selftest", "/tmp/model.gguf"],
            )
            XCTAssertEqual(mode, .model(path: "/tmp/model.gguf"))
        }

        func testFollowingFlagIsNotMistakenForAModelPath() {
            let mode = LocalVQESelftest.parse(
                arguments: ["/path/to/app", "--localvqe-selftest", "--auto-watch"],
            )
            XCTAssertEqual(mode, .linkOnly)
        }

        // MARK: - In-process probe runs (no model required)

        func testLinkOnlyProbeRunsTheLinkedLibraryAndSucceeds() {
            // The same code path the bundle check drives, minus the bundle:
            // backend listing plus the clean bogus-model failure.
            XCTAssertEqual(LocalVQESelftest.run(.linkOnly), 0)
        }

        func testModelProbeFailsCleanlyWhenTheModelCannotLoad() {
            // Exercises runModelProbe's async bridge and its failure branch.
            XCTAssertEqual(LocalVQESelftest.run(.model(path: "/nonexistent/model.gguf")), 1)
        }

        func testModelProbeSucceedsWithARealModel() throws {
            let model = try requireLocalVQEModel()
            XCTAssertEqual(LocalVQESelftest.run(.model(path: model)), 0)
        }

        // MARK: - Probe tone

        func testProbeToneMatchesLengthAndStaysWithinHalfScale() {
            let tone = LocalVQESelftest.probeFarEnd(seconds: 2)
            XCTAssertEqual(tone.count, 2 * AudioConstants.targetSampleRate)
            // The C API wants [-1, 1]; the tone deliberately keeps 6 dB of
            // headroom so the half-level mic copy stays well inside too.
            XCTAssertLessThanOrEqual(tone.map(abs).max() ?? 1, 0.5)
            // And it must not be silence, or the verdict divides noise floors.
            XCTAssertGreaterThan(AudioMixer.rmsDecibels(samples: tone), -40)
        }

        // MARK: - Reduction verdict

        // No test asserting `minReductionDb == 6`: that only fails when someone
        // deliberately edits the constant, and the two boundary cases below pin
        // the rule behaviourally, which is the assertion with meaning.

        func testVerdictFailsWhenTheEchoDoesNotDrop() {
            // The regression this type exists to prevent: an output identical
            // to the mic input must never pass the probe.
            let verdict = EchoReductionVerdict(beforeDbfs: -20, afterDbfs: -20)
            XCTAssertEqual(verdict.reductionDb, 0, accuracy: 0.01)
            XCTAssertFalse(verdict.passes)
        }

        func testVerdictAroundTheThreshold() {
            let floor = EchoReductionVerdict.minReductionDb
            XCTAssertFalse(EchoReductionVerdict(beforeDbfs: -20, afterDbfs: -20 - floor + 1).passes)
            XCTAssertTrue(EchoReductionVerdict(beforeDbfs: -20, afterDbfs: -20 - floor - 1).passes)
        }

        // Measurement is tested separately from the decision, because only this
        // one needs audio: it pins that `measure` reads the two levels off the
        // slices it is given rather than off the whole track.
        func testMeasureReadsTheLevelsOffTheGivenSlices() {
            let mic = LocalVQESelftest.probeFarEnd(seconds: 1)
            let quiet = mic.map { $0 * 0.001 }
            let verdict = EchoReductionVerdict.measure(mic: mic[...], output: quiet[...])
            XCTAssertEqual(verdict.reductionDb, 60, accuracy: 0.1)
            XCTAssertTrue(verdict.passes)
        }
    }
#endif
