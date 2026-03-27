@testable import AudioTapLib
import XCTest

final class SampleRateQueryTests: XCTestCase {
    // MARK: - validateSampleRate

    func testValidRatePassesThrough() {
        let result = SampleRateQuery.validateSampleRate(
            queriedRate: 48000,
            requestedRate: 48000
        )
        XCTAssertEqual(result.rate, 48000)
        XCTAssertEqual(result.source, .queriedMatchesRequested)
    }

    func testValidRateDiffersFromRequested() {
        let result = SampleRateQuery.validateSampleRate(
            queriedRate: 44100,
            requestedRate: 48000
        )
        XCTAssertEqual(result.rate, 44100)
        XCTAssertEqual(result.source, .queriedDiffersFromRequested)
    }

    func testZeroRateFallsBackToRequested() {
        let result = SampleRateQuery.validateSampleRate(
            queriedRate: 0,
            requestedRate: 48000
        )
        XCTAssertEqual(result.rate, 48000)
        XCTAssertEqual(result.source, .fallbackToRequested)
    }

    func testNegativeRateFallsBackToRequested() {
        let result = SampleRateQuery.validateSampleRate(
            queriedRate: -1,
            requestedRate: 48000
        )
        XCTAssertEqual(result.rate, 48000)
        XCTAssertEqual(result.source, .fallbackToRequested)
    }

    func testCommonUSBRatesAccepted() {
        for rate in [8000, 16000, 22050, 32000, 44100, 48000, 88200, 96000] {
            let result = SampleRateQuery.validateSampleRate(
                queriedRate: rate,
                requestedRate: 48000
            )
            XCTAssertEqual(result.rate, rate, "Rate \(rate) should be accepted")
            XCTAssertNotEqual(result.source, .fallbackToRequested)
        }
    }

    func testUnreasonablyHighRateFallsBack() {
        let result = SampleRateQuery.validateSampleRate(
            queriedRate: 1_000_000,
            requestedRate: 48000
        )
        XCTAssertEqual(result.rate, 48000)
        XCTAssertEqual(result.source, .fallbackToRequested)
    }

    // MARK: - crossValidateRate

    func testCrossValidationMatchingRates() {
        let result = SampleRateQuery.crossValidateRate(
            nominalRate: 48000,
            streamRate: 48000
        )
        XCTAssertEqual(result, .consistent(rate: 48000))
    }

    func testCrossValidationMismatch() {
        let result = SampleRateQuery.crossValidateRate(
            nominalRate: 48000,
            streamRate: 44100
        )
        XCTAssertEqual(result, .mismatch(nominal: 48000, stream: 44100))
    }

    func testCrossValidationOnlyNominal() {
        let result = SampleRateQuery.crossValidateRate(
            nominalRate: 48000,
            streamRate: 0
        )
        XCTAssertEqual(result, .onlyNominal(rate: 48000))
    }

    func testCrossValidationOnlyStream() {
        let result = SampleRateQuery.crossValidateRate(
            nominalRate: 0,
            streamRate: 44100
        )
        XCTAssertEqual(result, .onlyStream(rate: 44100))
    }

    func testCrossValidationBothZero() {
        let result = SampleRateQuery.crossValidateRate(
            nominalRate: 0,
            streamRate: 0
        )
        XCTAssertEqual(result, .neitherAvailable)
    }
}
