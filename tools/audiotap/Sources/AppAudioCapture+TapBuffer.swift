import CoreAudio
import Foundation
import os

private let logger = Logger(subsystem: "com.meetingtranscriber.audiotap", category: "AppAudioCapture")

/// Which buffer of the aggregate's input carries the process tap (issue #803).
///
/// The aggregate wraps the default output device as its main sub-device. When
/// that device also has inputs (an audio interface, a USB headset or
/// speakerphone), the aggregate exposes those input streams too, and the IOProc
/// receives one buffer per stream: the sub-device's own inputs first, the tap's
/// stream after them. Reading `mBuffers` (the first buffer) then records the
/// interface's microphone as the app track and drops the meeting audio,
/// measured on a MOTU M2: the app track came out as the microphone delayed by
/// 60 to 90 ms at half level, with no remote voice in either track.
///
/// Issue #712 is the virtual form of the same layout: a Loopback device or the
/// Teams loopback driver as system default also has an input stream, which
/// loops back whatever is played into that device. Read as the app track it
/// carried the meeting only while the meeting app played into that same
/// device, and went to zeros once it played to headphones instead.
///
/// The tap is the only tap on the aggregate and a stereo mixdown is a single
/// stream, so it is always the last buffer. With an output-only device it is
/// also the only one, which is the layout every recording had so far. That
/// rule has been measured on one interface; `logTapLayout` logs at every tap
/// build whether the stream counts agree with it, so a field log can say.
@available(macOS 14.2, *)
extension AppAudioCapture {
    /// Index of the tap's buffer among `bufferCount` input buffers, or nil when
    /// the callback delivered none.
    static func tapBufferIndex(bufferCount: Int) -> Int? {
        bufferCount > 0 ? bufferCount - 1 : nil
    }

    /// Log the aggregate's input layout once per tap build. Counts only, no
    /// device identity. The anchor is resolved from the UID the aggregate was
    /// bound with, so the count describes that device even if the default
    /// output has moved on since.
    static func logTapLayout(aggregateID: AudioObjectID, anchorUID: String) {
        let layout = TapLayout(
            anchorInputs: inputStreamCountReading(deviceID: deviceIDForUID(anchorUID)),
            aggregateInputs: inputStreamCountReading(deviceID: aggregateID),
        )
        let line = "Aggregate input layout: \(layout.summary), \(layout.verdict.phrase)"
        if layout.verdict.isWarning {
            logger.warning("\(line, privacy: .public)")
        } else {
            logger.info("\(line, privacy: .public)")
        }
    }

    /// The tap's buffer in an IOProc input list, or nil for an empty list.
    static func tapBuffer(in inputData: UnsafePointer<AudioBufferList>) -> AudioBuffer? {
        let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inputData))
        return tapBufferIndex(bufferCount: buffers.count).map { buffers[$0] }
    }
}

/// The two stream counts the "last buffer" rule rests on, read at tap build.
///
/// Readings rather than counts, because a device that is gone must not read as
/// a device with no inputs: an anchor that vanished between creation and this
/// read would otherwise turn an ordinary layout into an "unexpected" warning
/// and send a field report after the wrong cause.
@available(macOS 14.2, *)
struct TapLayout: Equatable {
    enum Verdict: Equatable {
        /// The buffer `tapBufferIndex` selects sits right after the anchor's inputs.
        case tapIsLast
        /// Both counts were read and it does not.
        case unexpected
        /// The aggregate has no input stream at all, so there is no tap stream
        /// to pick, which is a different failure from picking the wrong one.
        case noStreams
        /// At least one count could not be read, so nothing is claimed.
        case unknown

        var phrase: String {
            switch self {
            case .tapIsLast: "tap is the last stream"
            case .unexpected: "the last buffer may not be the tap (#712)"
            case .noStreams: "no input stream at all, so no tap stream to read"
            case .unknown: "could not tell whether the tap is the last stream"
            }
        }

        /// The two layouts a reader should act on. A failed read is a
        /// non-answer and stays at info.
        var isWarning: Bool {
            self == .unexpected || self == .noStreams
        }
    }

    let anchorInputs: ProcessOutputState.Reading<Int>
    let aggregateInputs: ProcessOutputState.Reading<Int>

    /// Asks the selection rule itself, so a change to `tapBufferIndex` moves
    /// the verdict with it instead of leaving the log vouching for the old rule.
    var verdict: Verdict {
        guard case let .value(anchor) = anchorInputs,
              case let .value(aggregate) = aggregateInputs else { return .unknown }
        guard let tapIndex = AppAudioCapture.tapBufferIndex(bufferCount: aggregate) else { return .noStreams }
        return tapIndex == anchor ? .tapIsLast : .unexpected
    }

    /// `inputStreams` is the aggregate's count under the same name the
    /// `App audio device (…)` lines use, so one search finds it at build,
    /// start and stop.
    var summary: String {
        "anchorInputs=\(anchorInputs.rendered) inputStreams=\(aggregateInputs.rendered)"
    }
}
