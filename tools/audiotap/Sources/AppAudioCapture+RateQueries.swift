import CoreAudio
import Foundation
import os

private let logger = Logger(subsystem: "com.meetingtranscriber.audiotap", category: "AppAudioCapture")

/// The sample-rate property queries and the priority ladder that picks between
/// them, split out of `AppAudioCapture.swift` to stay under the 600-line lint
/// cap. Pure CoreAudio reads plus a call into `SampleRateQuery`, unchanged by
/// the move except that the callers left behind in the main file mean they can
/// no longer be file-private.
///
/// These answer "what rate does this device say it runs at". What the tap is
/// actually delivering is a different question, measured per buffer by
/// `DeliveredRateTracker`, because a device can renegotiate in place without
/// telling anyone (issue #673) and, on some hardware, present one rate while
/// something below resamples to another (issue #82).
@available(macOS 14.2, *)
extension AppAudioCapture {
    /// Query nominal sample rate from a CoreAudio device.
    static func queryNominalSampleRate(deviceID: AudioObjectID) -> Int {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain,
        )
        var rate: Float64 = 0
        var size = UInt32(MemoryLayout<Float64>.size)
        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &rate)
        if status != noErr {
            logger.warning("queryNominalSampleRate failed (status: \(status))")
            return 0
        }
        return Int(rate)
    }

    /// Query physical stream format sample rate from a CoreAudio device.
    static func queryStreamSampleRate(deviceID: AudioObjectID) -> Int {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioStreamPropertyPhysicalFormat,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain,
        )
        var asbd = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &asbd)
        if status != noErr {
            // Not all devices support this query — non-fatal
            return 0
        }
        return Int(asbd.mSampleRate)
    }

    /// Query the tap's own format — most authoritative source for tap data rate.
    /// Uses kAudioTapPropertyFormat which returns the ASBD the tap delivers.
    static func queryTapSampleRate(tapID: AudioObjectID) -> Int {
        guard tapID != kAudioObjectUnknown else { return 0 }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyFormat,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain,
        )
        var asbd = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        let status = AudioObjectGetPropertyData(tapID, &address, 0, nil, &size, &asbd)
        if status != noErr {
            logger.warning("queryTapSampleRate failed (status: \(status))")
            return 0
        }
        return Int(asbd.mSampleRate)
    }

    /// Query the actual measured sample rate from a running device.
    /// Only valid after AudioDeviceStart — returns the hardware-measured rate.
    static func queryActualSampleRate(deviceID: AudioObjectID) -> Int {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyActualSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain,
        )
        var rate: Float64 = 0
        var size = UInt32(MemoryLayout<Float64>.size)
        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &rate)
        if status != noErr { return 0 }
        return Int(rate)
    }

    /// Query, cross-validate, and return the best available sample rate for a device.
    /// Priority: tap format > nominal rate > stream format > requested rate.
    static func resolveActualSampleRate(
        deviceID: AudioObjectID,
        tapID: AudioObjectID,
        requestedRate: Int,
    ) -> Int {
        // Query the tap directly first — most authoritative. Only cross-validate
        // nominal + stream when the tap has no rate, preserving the original
        // short-circuit (no extra hardware queries when the tap answers).
        let tapRate = queryTapSampleRate(tapID: tapID)
        let nominalRate = tapRate > 0 ? 0 : queryNominalSampleRate(deviceID: deviceID)
        let streamRate = tapRate > 0 ? 0 : queryStreamSampleRate(deviceID: deviceID)

        let decision = SampleRateQuery.chooseRate(
            tapRate: tapRate, nominalRate: nominalRate, streamRate: streamRate, requestedRate: requestedRate,
        )

        switch decision.source {
        case .tap:
            if decision.differsFromRequested {
                logger.warning("Tap rate \(tapRate) Hz differs from requested \(requestedRate) Hz")
            }
            logger.info("Using tap format rate: \(tapRate) Hz")
            return decision.rate

        case .requestedFallback:
            logger.warning("Cannot query sample rate, using requested \(requestedRate) Hz")
            return decision.rate

        case .mismatchPreferNominal:
            // Prefer nominal over stream — stream on output scope can return BT HFP rate
            logger.warning("Rate mismatch: nominal=\(nominalRate), stream=\(streamRate) — using nominal rate (stream scope may reflect BT HFP)")

        case .consistent, .onlyNominal, .onlyStream:
            break
        }

        // Cross-validated rungs (consistent / mismatch / onlyNominal / onlyStream):
        // flag when the queried rate the ladder picked differs from requested.
        if decision.differsFromRequested {
            logger.warning("Aggregate device rate \(decision.rate) Hz differs from requested \(requestedRate) Hz")
        }
        return decision.rate
    }
}
