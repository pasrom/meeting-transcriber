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

    // MARK: - snapToStandardRate

    func testSnapExact48000() {
        XCTAssertEqual(SampleRateQuery.snapToStandardRate(48000), 48000)
    }

    func testSnapExact44100() {
        XCTAssertEqual(SampleRateQuery.snapToStandardRate(44100), 44100)
    }

    func testSnapNear48000() {
        XCTAssertEqual(SampleRateQuery.snapToStandardRate(47950), 48000)
        XCTAssertEqual(SampleRateQuery.snapToStandardRate(48050), 48000)
    }

    func testSnapNear44100() {
        XCTAssertEqual(SampleRateQuery.snapToStandardRate(44000), 44100)
        XCTAssertEqual(SampleRateQuery.snapToStandardRate(44200), 44100)
    }

    func testSnapNear24000() {
        XCTAssertEqual(SampleRateQuery.snapToStandardRate(23900), 24000)
        XCTAssertEqual(SampleRateQuery.snapToStandardRate(24100), 24000)
    }

    func testSnapNear16000() {
        XCTAssertEqual(SampleRateQuery.snapToStandardRate(15900), 16000)
    }

    // MARK: - inferRateFromDuration

    func testInferRate48kStereo60s() {
        let result = SampleRateQuery.inferRateFromDuration(
            rawBytes: 23_040_000, bytesPerSample: 4, channels: 2, durationSeconds: 60.0
        )
        XCTAssertEqual(result, 48000)
    }

    func testInferRate44100Stereo60s() {
        let result = SampleRateQuery.inferRateFromDuration(
            rawBytes: 21_168_000, bytesPerSample: 4, channels: 2, durationSeconds: 60.0
        )
        XCTAssertEqual(result, 44100)
    }

    func testInferRate24kMono30s() {
        let result = SampleRateQuery.inferRateFromDuration(
            rawBytes: 30 * 24000 * 1 * 4, bytesPerSample: 4, channels: 1, durationSeconds: 30.0
        )
        XCTAssertEqual(result, 24000)
    }

    func testInferRateZeroBytesReturnsNil() {
        let result = SampleRateQuery.inferRateFromDuration(
            rawBytes: 0, bytesPerSample: 4, channels: 2, durationSeconds: 60.0
        )
        XCTAssertNil(result)
    }

    func testInferRateTooShortReturnsNil() {
        let result = SampleRateQuery.inferRateFromDuration(
            rawBytes: 48000 * 4, bytesPerSample: 4, channels: 1, durationSeconds: 0.5
        )
        XCTAssertNil(result)
    }

    func testInferRateImplausibleHighReturnsNil() {
        let result = SampleRateQuery.inferRateFromDuration(
            rawBytes: 500_000 * 4 * 2 * 60, bytesPerSample: 4, channels: 2, durationSeconds: 60.0
        )
        XCTAssertNil(result)
    }
}
