import Foundation

/// Validated sample rate result.
public struct ValidatedSampleRate: Equatable, Sendable {
    public let rate: Int
    public let source: SampleRateSource
}

/// How the sample rate was determined.
public enum SampleRateSource: Equatable, Sendable {
    /// Queried rate matches requested rate — ideal case.
    case queriedMatchesRequested
    /// Queried rate is valid but differs from requested — USB device negotiated different rate.
    case queriedDiffersFromRequested
    /// Query returned invalid rate, using requested rate as fallback.
    case fallbackToRequested
}

/// Cross-validation result between nominal and stream rates.
public enum CrossValidationResult: Equatable, Sendable {
    case consistent(rate: Int)
    case mismatch(nominal: Int, stream: Int)
    case onlyNominal(rate: Int)
    case onlyStream(rate: Int)
    case neitherAvailable
}

/// Pure functions for sample rate detection and validation.
/// No CoreAudio dependency — testable without hardware.
public enum SampleRateQuery {
    /// Maximum plausible audio sample rate (384kHz is the highest standard rate).
    static let maxPlausibleRate = 384_000

    /// Validate a queried sample rate against the requested rate.
    public static func validateSampleRate(
        queriedRate: Int,
        requestedRate: Int,
    ) -> ValidatedSampleRate {
        guard queriedRate > 0, queriedRate <= maxPlausibleRate else {
            return ValidatedSampleRate(rate: requestedRate, source: .fallbackToRequested)
        }
        let source: SampleRateSource = queriedRate == requestedRate
            ? .queriedMatchesRequested
            : .queriedDiffersFromRequested
        return ValidatedSampleRate(rate: queriedRate, source: source)
    }

    /// Cross-validate nominal device rate against stream physical format rate.
    /// When both are available and differ, the stream rate is more trustworthy.
    public static func crossValidateRate(
        nominalRate: Int,
        streamRate: Int,
    ) -> CrossValidationResult {
        let nominalValid = nominalRate > 0
        let streamValid = streamRate > 0

        switch (nominalValid, streamValid) {
        case (true, true) where nominalRate == streamRate:
            return .consistent(rate: nominalRate)

        case (true, true):
            return .mismatch(nominal: nominalRate, stream: streamRate)

        case (true, false):
            return .onlyNominal(rate: nominalRate)

        case (false, true):
            return .onlyStream(rate: streamRate)

        case (false, false):
            return .neitherAvailable
        }
    }
}
