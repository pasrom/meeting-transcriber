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

/// Which rung of the sample-rate priority ladder produced the resolved rate.
/// Lets the caller emit the same diagnostics after delegating the decision.
public enum RateSource: Equatable, Sendable {
    case tap // authoritative tap format rate
    case consistent // nominal == stream
    case mismatchPreferNominal // nominal != stream, nominal chosen (BT HFP guard, #379)
    case onlyNominal
    case onlyStream
    case requestedFallback // nothing queryable, requested rate used verbatim
}

/// Outcome of the sample-rate priority ladder.
public struct ResolvedRate: Equatable, Sendable {
    public let rate: Int
    public let source: RateSource
    /// The queried rate the ladder picked was valid but differed from the
    /// requested rate (drives the "differs from requested" warnings). Always
    /// false for `.requestedFallback`.
    public let differsFromRequested: Bool
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

    /// Sample-rate priority ladder: tap > nominal > stream > requested. The
    /// mismatch rung prefers nominal over stream because an output-scope stream
    /// can report a Bluetooth HFP rate (#379 family). Composes `validateSampleRate`
    /// + `crossValidateRate`; the returned `source` mirrors the rung taken so the
    /// CoreAudio caller can emit the same diagnostics. Pass 0 for any rate that
    /// could not be queried.
    public static func chooseRate(
        tapRate: Int,
        nominalRate: Int,
        streamRate: Int,
        requestedRate: Int,
    ) -> ResolvedRate {
        // 1. Tap rate is most authoritative.
        if tapRate > 0 {
            let validated = validateSampleRate(queriedRate: tapRate, requestedRate: requestedRate)
            return ResolvedRate(
                rate: validated.rate, source: .tap,
                differsFromRequested: validated.source == .queriedDiffersFromRequested,
            )
        }

        // 2. Fall back to nominal + stream cross-validation.
        let bestRate: Int
        let source: RateSource
        switch crossValidateRate(nominalRate: nominalRate, streamRate: streamRate) {
        case let .consistent(rate):
            bestRate = rate
            source = .consistent

        case let .mismatch(nominal, _):
            bestRate = nominal
            source = .mismatchPreferNominal

        case let .onlyNominal(rate):
            bestRate = rate
            source = .onlyNominal

        case let .onlyStream(rate):
            bestRate = rate
            source = .onlyStream

        case .neitherAvailable:
            return ResolvedRate(rate: requestedRate, source: .requestedFallback, differsFromRequested: false)
        }

        let validated = validateSampleRate(queriedRate: bestRate, requestedRate: requestedRate)
        return ResolvedRate(
            rate: validated.rate, source: source,
            differsFromRequested: validated.source == .queriedDiffersFromRequested,
        )
    }

    /// Standard audio sample rates for snap-to-nearest matching.
    private static let standardRates = [
        8000, 11025, 16000, 22050, 24000, 32000, 44100, 48000,
        88200, 96000, 176_400, 192_000,
    ]

    /// Snap an inferred rate to the nearest standard audio sample rate.
    public static func snapToStandardRate(_ raw: Int) -> Int {
        standardRates.min { abs($0 - raw) < abs($1 - raw) } ?? raw
    }

    /// How far a measurement may sit from a rate before it counts as a different
    /// rate. CoreAudio's own clock drift is parts per million (+/-50 ppm is
    /// 0.005 %); one dropped 10 ms buffer inside a 0.5 s window is 2 %. 0.5 %
    /// separates the two with room on both sides.
    static let rateTolerance = 0.005

    /// Decide whether a measured delivered rate means the published rate is
    /// wrong, and if so what to publish instead (issue #673).
    ///
    /// Two guards, both load bearing. The first is against churn: a measurement
    /// within tolerance of what is already published returns nil, so ordinary
    /// jitter never rebuilds the converter and `Int()` truncation cannot flip a
    /// rate between 47999 and 48000 forever. The second is against transitional
    /// windows: a window that straddles a 48 to 24 kHz switch measures something
    /// in between, and merely snapping it to the nearest standard rate would
    /// adopt a rate nothing is delivering (44160 is within 0.14 % of 44100).
    /// Requiring the measurement to be *close to* the rate it snapped onto
    /// rejects that, and the caller's confirmation requirement rejects the rest.
    ///
    /// `current <= 0` means nothing has been resolved yet, so any plausible
    /// standard measurement is accepted.
    public static func confirmedRateChange(measured: Double, current: Int) -> Int? {
        guard measured.isFinite, measured > 0, measured <= Double(maxPlausibleRate) else {
            return nil
        }
        if current > 0, abs(measured - Double(current)) <= Double(current) * rateTolerance {
            return nil
        }
        let snapped = snapToStandardRate(Int(measured.rounded()))
        guard snapped != current, snapped > 0 else { return nil }
        guard abs(measured - Double(snapped)) <= Double(snapped) * rateTolerance else { return nil }
        return snapped
    }

    /// Infer sample rate from raw PCM file size and known recording duration.
    /// Returns nil if data is insufficient or result is implausible.
    public static func inferRateFromDuration(
        rawBytes: Int,
        bytesPerSample: Int,
        channels: Int,
        durationSeconds: Double,
    ) -> Int? {
        guard rawBytes > 0, bytesPerSample > 0, channels > 0, durationSeconds > 1.0 else {
            return nil
        }
        let totalSamples = rawBytes / bytesPerSample / channels
        let rate = Double(totalSamples) / durationSeconds
        guard rate > 7000, rate < Double(maxPlausibleRate) else { return nil }
        return Int(rate.rounded())
    }
}
