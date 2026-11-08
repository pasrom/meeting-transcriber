@testable import MeetingTranscriber
import XCTest

final class CaptionLanguageProbeDecisionTests: XCTestCase {
    private let english = CaptionLanguageDetection(language: "en", probability: 0.8)
    private let unsure = CaptionLanguageDetection(language: "en", probability: 0.79)

    func testTwoConfidentEnglishWindowsSelectStreamingAtThresholdAndLatch() {
        var decision = CaptionLanguageProbeDecision()
        XCTAssertNil(decision.resolve(english), "one English window is not enough")
        XCTAssertEqual(decision.resolve(english), .englishStreaming)
        XCTAssertEqual(decision.attempts, 2)
        XCTAssertNil(decision.resolve(CaptionLanguageDetection(language: "de", probability: 1)))
    }

    func testEnglishGreetingBeforeAnotherLanguageKeepsRetranscription() {
        var decision = CaptionLanguageProbeDecision()
        XCTAssertNil(decision.resolve(CaptionLanguageDetection(language: "en", probability: 0.99)))
        XCTAssertEqual(decision.resolve(CaptionLanguageDetection(language: "de", probability: 0.95)), .reTranscribe)
    }

    func testUnsureWindowBreaksTheEnglishStreak() {
        var decision = CaptionLanguageProbeDecision()
        XCTAssertNil(decision.resolve(english))
        XCTAssertNil(decision.resolve(unsure))
        XCTAssertNil(decision.resolve(english))
        XCTAssertEqual(decision.resolve(english), .englishStreaming)
        XCTAssertEqual(decision.attempts, 4)
    }

    func testEnglishStreakDoesNotOutliveTheAttemptCap() {
        var decision = CaptionLanguageProbeDecision()
        XCTAssertNil(decision.resolve(english))
        XCTAssertNil(decision.resolve(unsure))
        XCTAssertNil(decision.resolve(unsure))
        XCTAssertEqual(decision.resolve(english), .reTranscribe)
        XCTAssertEqual(decision.attempts, 4)
        XCTAssertNil(decision.resolve(english))
    }

    func testConfidentOtherLanguageKeepsRetranscription() {
        for language in ["de", "id", "id-ID"] {
            var decision = CaptionLanguageProbeDecision()
            XCTAssertEqual(decision.resolve(CaptionLanguageDetection(language: language, probability: 0.95)), .reTranscribe)
            XCTAssertNil(decision.resolve(CaptionLanguageDetection(language: "en", probability: 1)))
        }
    }

    func testLowConfidenceRetriesAndFallsBackOnLastAttempt() {
        var decision = CaptionLanguageProbeDecision()
        for _ in 1 ..< CaptionLanguageProbeDecision.maxAttempts {
            XCTAssertNil(decision.resolve(unsure))
        }
        XCTAssertEqual(decision.resolve(unsure), .reTranscribe)
        XCTAssertEqual(decision.attempts, CaptionLanguageProbeDecision.maxAttempts)
        XCTAssertNil(decision.resolve(CaptionLanguageDetection(language: "en", probability: 1)))
    }

    func testUnsupportedOrThrownDetectionFallsBackImmediately() {
        var unsupported = CaptionLanguageProbeDecision()
        XCTAssertEqual(unsupported.resolve(nil), .reTranscribe)
        XCTAssertEqual(unsupported.attempts, 1)
        var thrown = CaptionLanguageProbeDecision()
        // The controller turns a detection error into nil for this decision.
        XCTAssertEqual(thrown.resolve(nil), .reTranscribe)
    }
}
