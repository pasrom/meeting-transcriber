import Foundation

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
    case consistent // nominal == stream
    case mismatchPreferNominal // nominal != stream, nominal chosen (BT HFP guard, #379)
    case onlyNominal
    /// Only the output-scope stream format answered, and the ladder did not
    /// take it. See `chooseRate` for why that property is never the answer on
    /// its own; the rate returned is the requested one.
    case streamOnlyDistrusted
    case requestedFallback // nothing queryable, requested rate used verbatim

    /// What the capture log prints for this rung. Spelled out rather than
    /// reflected off the case name, because the log line's shape is documented
    /// and a Swift rename would otherwise change it without touching the docs.
    public var logLabel: String {
        switch self {
        case .consistent: "nominal and stream agree"
        case .mismatchPreferNominal: "nominal, stream disagreed"
        case .onlyNominal: "nominal only"
        case .streamOnlyDistrusted: "stream only, not trusted"
        case .requestedFallback: "nothing queryable"
        }
    }
}

/// Outcome of the sample-rate priority ladder.
public struct ResolvedRate: Equatable, Sendable {
    public let rate: Int
    public let source: RateSource
}

/// Pure functions for sample rate detection and validation.
/// No CoreAudio dependency — testable without hardware.
public enum SampleRateQuery {
    /// Maximum plausible audio sample rate (384kHz is the highest standard rate).
    static let maxPlausibleRate = 384_000

    /// A queried rate if it is plausible, the requested rate otherwise. Zero is
    /// the callers' "could not be queried" signal, so it falls back like any
    /// other implausible value.
    ///
    /// It used to also report *how* the rate was arrived at, which nothing read:
    /// the rung is what the caller wants, and `chooseRate` already returns that.
    public static func validateSampleRate(queriedRate: Int, requestedRate: Int) -> Int {
        guard queriedRate > 0, queriedRate <= maxPlausibleRate else { return requestedRate }
        return queriedRate
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

    /// Sample-rate priority ladder: nominal > requested, with the stream format
    /// as corroboration only.
    ///
    /// The output-scope stream format never decides on its own. It is the
    /// property issue #82 was filed over: on a Bluetooth headset in call mode it
    /// reports the HFP link rate (24 kHz measured) rather than the rate the tap
    /// delivers at, and the commit that fixed #82 called this selector "wrong
    /// scope" for that reason. The mismatch rung has always distrusted it and
    /// taken nominal. Trusting it completely the moment nominal falls silent was
    /// the same property treated two opposite ways, and it only became reachable
    /// when the tap rung above it was removed, so it is closed here rather than
    /// shipped. What it still buys is the disagreement warning, which needs both
    /// reads, so both are still made every time. Composes `validateSampleRate`
    /// + `crossValidateRate`; the returned `source` mirrors the rung taken so the
    /// CoreAudio caller can emit the same diagnostics. Pass 0 for any rate that
    /// could not be queried.
    ///
    /// There is deliberately no rung for the process tap's own format
    /// (`kAudioTapPropertyFormat`). A stereo-mixdown tap is not attached to any
    /// device's stream and reports a fixed 48 kHz whatever rate the aggregate
    /// delivers at (issue #683: measured 48000 with the device at 44.1, 48 and
    /// 96 kHz), so it carries no information about the buffers and, placed on
    /// top, it made the two rungs below unreachable.
    public static func chooseRate(
        nominalRate: Int,
        streamRate: Int,
        requestedRate: Int,
    ) -> ResolvedRate {
        // The nominal rate is the only one this ever adopts, which is easier to
        // see stated than reconstructed: every rung that resolves to a rate
        // resolves to that one, and every rung that does not leaves nominal at
        // zero, which `validateSampleRate` turns into the requested rate. The
        // stream read is a classifier for the diagnostics, never an answer, so a
        // lone stream answer leaves nominal at zero and the requested rate comes
        // out.
        //
        // What corrects it from there, and the limit of that, stated because it
        // is tempting to claim more: the first-callback `ActualSampleRate` read
        // fixes the rate before the first buffer is resampled, but only if it
        // answers. A zero from it is not retried, and then the delivered-rate
        // tracker is what corrects the rate, about a second in. So a device
        // whose nominal read fails, whose actual read also fails, and which is
        // not at the requested rate spends that second resampled wrongly. Both
        // reads failing on an aggregate we just created is not a case anyone has
        // observed; adopting a property known to misreport on Bluetooth is.
        let source: RateSource = switch crossValidateRate(
            nominalRate: nominalRate, streamRate: streamRate,
        ) {
        case .consistent: .consistent
        case .mismatch: .mismatchPreferNominal
        case .onlyNominal: .onlyNominal
        case .onlyStream: .streamOnlyDistrusted
        case .neitherAvailable: .requestedFallback
        }
        return ResolvedRate(
            rate: validateSampleRate(queriedRate: nominalRate, requestedRate: requestedRate),
            source: source,
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
