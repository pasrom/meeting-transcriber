import AVFoundation
import Foundation

extension MicCaptureHandler {
    /// Silence or restore the track from the next buffer on. The engine keeps
    /// running: reopening the input is what can flip a Bluetooth headset's profile
    /// and wedge (issues #693, #588), which is not a risk a mute button should take.
    @discardableResult
    public func setMuted(_ muted: Bool) -> MicMuteTimeline {
        muteTimeline.withLock { timeline in
            timeline.setMuted(muted)
            return timeline
        }
    }

    /// The muted stretches of the track, with one still open closed where the
    /// track currently ends.
    public var muteIntervals: [MicMuteInterval] {
        muteTimeline.withLock { $0.intervals(endingAt: $0.position) }
    }

    /// Zeroes after any conversion, so the resampler state stays continuous
    /// across a mute.
    func writeCaptured(_ buffer: AVAudioPCMBuffer, before when: AVAudioTime, isMuted: Bool) throws {
        if isMuted { Self.zeroSamples(of: buffer) }
        fillTimelineGap(before: when, outputFrames: Int(buffer.frameLength))
        try outputFile?.write(from: buffer)
        noteWrittenTrackLength()
        forwardToLiveSink(buffer: buffer)
    }

    static func zeroSamples(of buffer: AVAudioPCMBuffer) {
        let frames = Int(buffer.frameLength)
        for channel in 0 ..< Int(buffer.format.channelCount) {
            buffer.floatChannelData?[channel].update(repeating: 0, count: frames)
            buffer.int16ChannelData?[channel].update(repeating: 0, count: frames)
        }
    }

    func noteWrittenTrackLength() {
        guard let length = outputFile?.length else { return }

        let position = Double(length) / speechSampleRate
        muteTimeline.withLock { $0.advance(to: position) }
    }
}
