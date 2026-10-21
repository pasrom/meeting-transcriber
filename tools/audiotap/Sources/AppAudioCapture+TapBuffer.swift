import CoreAudio
import Foundation

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
/// The tap is the only tap on the aggregate and a stereo mixdown is a single
/// stream, so it is always the last buffer. With an output-only device it is
/// also the only one, which is the layout every recording had so far.
@available(macOS 14.2, *)
extension AppAudioCapture {
    /// Index of the tap's buffer among `bufferCount` input buffers, or nil when
    /// the callback delivered none.
    static func tapBufferIndex(bufferCount: Int) -> Int? {
        bufferCount > 0 ? bufferCount - 1 : nil
    }

    /// The tap's buffer in an IOProc input list, or nil for an empty list.
    static func tapBuffer(in inputData: UnsafePointer<AudioBufferList>) -> AudioBuffer? {
        let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inputData))
        return tapBufferIndex(bufferCount: buffers.count).map { buffers[$0] }
    }
}
