@preconcurrency import AVFoundation

/// Reading a span of an `AVAudioFile` a chunk at a time, split out of
/// `AudioMixer.swift` to keep that file under the `file_length` limit.
extension AudioMixer {
    /// Frames one read of `readFrames` asks for.
    private static let readChunkFrames = 65536

    /// Reads the next `count` frames of `file` from its current position, a
    /// chunk at a time, handing each chunk's channels and frame count to
    /// `consume`. Returns the frames read: fewer than `count` when the file
    /// ends first or a read returns no frames, so `count` may run past the
    /// end of the file. A call that starts where the decodable audio already
    /// ends throws, with `eofErr` in `NSOSStatusErrorDomain`; one that gets
    /// there after reading frames returns what it read.
    ///
    /// Spans are read through here rather than with one `read(into:)` sized
    /// to the span, because that read can return short without an error: from
    /// the start of a mono float file (see `readSamplesFromAudioFile`), and
    /// after a seek even for a span shorter than one chunk (16,384 frames from
    /// frame 50,000 read as 15,536, measured on macOS 27.2.1).
    static func readFrames(
        from file: AVAudioFile, count: Int,
        consume: (_ channels: UnsafePointer<UnsafeMutablePointer<Float>>, _ frames: Int) throws -> Void,
    ) throws -> Int {
        guard count > 0 else { return 0 }
        guard let chunk = AVAudioPCMBuffer(
            pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(min(count, readChunkFrames)),
        ) else {
            throw AudioMixerError.bufferCreationFailed
        }
        return try readAllFrames(total: count) { maxFrames in
            try file.read(into: chunk, frameCount: AVAudioFrameCount(min(maxFrames, Int(chunk.frameCapacity))))
            guard let floatData = chunk.floatChannelData else {
                throw AudioMixerError.noFloatData
            }
            let frames = Int(chunk.frameLength)
            try consume(floatData, frames)
            return frames
        }
    }
}
