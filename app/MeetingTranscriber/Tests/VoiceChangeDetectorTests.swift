@testable import MeetingTranscriber
import XCTest

final class VoiceChangeDetectorTests: XCTestCase {
    private func voice(_ name: String, distance: Float = 0.3, margin: Float? = 0.3) -> LiveSpeakerMatch {
        LiveSpeakerMatch(name: nil, closest: name, distance: distance, margin: margin)
    }

    /// The first voice confirmed is the current one; another takes over after three windows in a
    /// row, from the middle of its first window.
    func testAnotherVoiceTakesOverAfterThreeWindowsInARow() {
        var detector = VoiceChangeDetector()
        for end in [1.5, 2.0, 2.5] {
            XCTAssertNil(detector.add(windowEnd: end, match: voice("Speaker A")))
        }
        XCTAssertEqual(detector.current, "Speaker A")
        XCTAssertNil(detector.add(windowEnd: 3.0, match: voice("Speaker B")))
        XCTAssertNil(detector.add(windowEnd: 3.5, match: voice("Speaker B")))
        XCTAssertEqual(
            detector.add(windowEnd: 4.0, match: voice("Speaker B")),
            VoiceChangeDetector.Change(at: 2.25, voice: "Speaker B"),
        )
        XCTAssertEqual(detector.current, "Speaker B")
        XCTAssertNil(detector.add(windowEnd: 4.5, match: voice("Speaker B")))
    }

    /// One stray first window does not become the current voice, or the real first speaker would be
    /// reported as a change three windows later and their line cut.
    func testTheFirstVoiceNeedsThreeWindowsTooAndIsNoChange() {
        var detector = VoiceChangeDetector()
        XCTAssertNil(detector.add(windowEnd: 1.5, match: voice("Speaker C")))
        XCTAssertNil(detector.current)
        for end in [2.0, 2.5, 3.0] {
            XCTAssertNil(detector.add(windowEnd: end, match: voice("Speaker A")))
        }
        XCTAssertEqual(detector.current, "Speaker A")
    }

    /// One or two windows of another voice in a long turn are noise; on a two-speaker recording,
    /// single windows of unrelated enrolled voices came up but never three in a row.
    func testWindowsOfTheCurrentVoiceOrAThirdVoiceRestartTheCount() {
        var detector = VoiceChangeDetector()
        for end in [0.5, 1.0, 1.5] {
            _ = detector.add(windowEnd: end, match: voice("Speaker A"))
        }
        let sequence = ["Speaker B", "Speaker B", "Speaker A", "Speaker B", "Speaker C", "Speaker B", "Speaker B"]
        for (index, name) in sequence.enumerated() {
            XCTAssertNil(detector.add(windowEnd: 2.0 + Double(index) * 0.5, match: voice(name)), "window \(index)")
        }
        XCTAssertEqual(detector.current, "Speaker A")
    }

    /// Far, close to the runner-up, or silent: the window names no one and breaks the run.
    func testUncertainWindowsBreakTheRun() {
        let uncertain = [
            voice("Speaker B", distance: VoiceChangeDetector.maxDistance),
            // Where the unenrolled voice of the offline run came within reach at the earlier 0.6.
            voice("Speaker B", distance: 0.55),
            voice("Speaker B", margin: VoiceChangeDetector.minMargin - 0.01),
            LiveSpeakerMatch.unknown,
        ]
        for window in uncertain {
            var detector = VoiceChangeDetector()
            for end in [0.5, 1.0, 1.5] {
                _ = detector.add(windowEnd: end, match: voice("Speaker A"))
            }
            _ = detector.add(windowEnd: 2.0, match: voice("Speaker B"))
            _ = detector.add(windowEnd: 2.5, match: voice("Speaker B"))
            XCTAssertNil(detector.add(windowEnd: 3.0, match: window))
            XCTAssertNil(detector.add(windowEnd: 3.5, match: voice("Speaker B")))
            XCTAssertEqual(detector.current, "Speaker A")
        }
    }
}
