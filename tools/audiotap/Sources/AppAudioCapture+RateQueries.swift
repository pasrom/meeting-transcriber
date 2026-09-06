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
/// telling anyone (issue #673) and, on some hardware, one of its properties
/// describes a link the buffers do not travel (issue #82: the output-scope
/// stream format reported the Bluetooth HFP rate while the IOProc delivered
/// the nominal one).
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

    /// Query, cross-validate, and return the best available sample rate for a
    /// device. The rate is the nominal one when it can be read and the requested
    /// default otherwise; the stream format only corroborates it, never decides.
    /// Returns the whole decision so the caller can say which rung it came from.
    ///
    /// Both device properties are read every time. The tap's own format is not
    /// consulted: a stereo-mixdown tap reports a fixed 48 kHz whatever the
    /// aggregate runs at (issue #683), and letting that answer skip the device
    /// reads is exactly how a constant passed for a measurement.
    static func resolveActualSampleRate(
        requestedRate: Int,
        queries: DeviceRateQueries,
    ) -> ResolvedRate {
        let nominalRate = queries.nominal()
        let streamRate = queries.stream()

        let decision = SampleRateQuery.chooseRate(
            nominalRate: nominalRate, streamRate: streamRate, requestedRate: requestedRate,
        )

        // A device rate that differs from the requested one is not warned
        // about here: nothing asks the aggregate for a rate, so "requested" is
        // the fallback default, and a 44.1 or 96 kHz output device is a normal
        // configuration rather than a fault. The caller logs the resolved rate
        // and its rung at info. Two properties disagreeing is still a warning.
        switch decision.source {
        case .requestedFallback:
            logger.warning("Cannot query sample rate, using requested \(requestedRate) Hz")

        case .mismatchPreferNominal:
            // Prefer nominal over stream: an output-scope stream can report the BT HFP rate.
            logger.warning("Rate mismatch: nominal=\(nominalRate), stream=\(streamRate), using nominal rate (stream scope may reflect BT HFP)")

        case .streamOnlyDistrusted:
            logger.warning(
                "Only the stream format answered (\(streamRate) Hz); not trusted alone (BT HFP), using requested \(requestedRate) Hz",
            )

        case .consistent, .onlyNominal:
            break
        }
        return decision
    }
}

/// The property reads the rate ladder composes, bound to the objects they are
/// asked of and injectable so the composition can be asserted without a
/// device. `.real` is the only one that ships; a test hands the ladder the
/// answers a device would have given and checks which of them it believed.
@available(macOS 14.2, *)
struct DeviceRateQueries {
    var nominal: () -> Int
    var stream: () -> Int

    static func real(deviceID: AudioObjectID) -> Self {
        Self(
            nominal: { AppAudioCapture.queryNominalSampleRate(deviceID: deviceID) },
            stream: { AppAudioCapture.queryStreamSampleRate(deviceID: deviceID) },
        )
    }
}
