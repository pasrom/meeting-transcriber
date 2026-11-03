import AVFoundation
import Foundation

/// Serializes the engine's blocking file work away from the main actor. Calls
/// stay in the transcription task so cancellation reaches each read and copy.
actor CloudUploadPreparation {
    /// Plans the pieces of the WAV at `url`; a single piece means no split.
    func planPieces(
        of url: URL, pieceDuration: TimeInterval, searchWindow: TimeInterval, maxPassthroughBytes: Int,
    ) throws -> (pieces: [Range<Int>], sampleRate: Double, sendOriginal: Bool)? {
        do {
            try Task.checkCancellation()
            let file = try AVAudioFile(forReading: url)
            let rate = file.processingFormat.sampleRate
            let pieces = try CloudAudioSplitter.planPieces(
                totalFrames: Int(file.length),
                pieceFrames: max(1, Int(pieceDuration * rate)),
                windowFrames: Int(searchWindow * rate),
                sampleRate: rate,
            ) { range in
                try Task.checkCancellation()
                let buffer = try read(file, range: range)
                // swiftlint:disable:next force_unwrapping
                return Array(UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength)))
            }
            let sendOriginal = pieces.count == 1 && ((try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0) <= maxPassthroughBytes
            return (pieces, rate, sendOriginal)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return nil
        }
    }

    /// Writes `range` of `source` to `destination` as 16-bit PCM, a chunk at a
    /// time, whatever the source's sample format.
    func writePiece(of source: URL, range: Range<Int>, to destination: URL) throws {
        let input = try AVAudioFile(forReading: source)
        let format = input.processingFormat
        let output = try AVAudioFile(
            forWriting: destination,
            settings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: format.sampleRate,
                AVNumberOfChannelsKey: format.channelCount,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
            ],
            commonFormat: format.commonFormat,
            interleaved: format.isInterleaved,
        )
        let chunk = Int(format.sampleRate) * 10
        var position = range.lowerBound
        while position < range.upperBound {
            try Task.checkCancellation()
            let end = min(position + chunk, range.upperBound)
            try output.write(from: read(input, range: position ..< end))
            position = end
        }
    }

    private func read(_ file: AVAudioFile, range: Range<Int>) throws -> AVAudioPCMBuffer {
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(range.count)) else {
            throw AudioMixerError.bufferCreationFailed
        }
        file.framePosition = AVAudioFramePosition(range.lowerBound)
        try file.read(into: buffer, frameCount: AVAudioFrameCount(range.count))
        return buffer
    }

    /// Streams the multipart body to disk so a long recording is never held
    /// in memory twice. A write that fails halfway (a full disk, an unreadable
    /// recording) removes what it wrote, so no partial copy of the audio stays.
    func writeMultipartBody(
        to destination: URL, boundary: String, audioPath: URL, model: String,
        fields extra: [(name: String, value: String)] = [],
    ) throws {
        do {
            try streamMultipartBody(to: destination, boundary: boundary, audioPath: audioPath, model: model, fields: extra)
        } catch {
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
    }

    private func streamMultipartBody(
        to destination: URL, boundary: String, audioPath: URL, model: String,
        fields extra: [(name: String, value: String)],
    ) throws {
        FileManager.default.createFile(atPath: destination.path, contents: nil)
        let out = try FileHandle(forWritingTo: destination)
        defer { try? out.close() }

        func field(_ name: String, _ value: String) -> Data {
            Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".utf8)
        }
        try out.write(contentsOf: field("model", model))
        try out.write(contentsOf: field("response_format", "verbose_json"))
        try out.write(contentsOf: field("timestamp_granularities[]", "segment"))
        for (name, value) in extra {
            try out.write(contentsOf: field(name, value))
        }
        try out.write(contentsOf: Data((
            "--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"\(audioPath.lastPathComponent)\"\r\n"
                + "Content-Type: audio/wav\r\n\r\n"
        ).utf8))

        let input = try FileHandle(forReadingFrom: audioPath)
        defer { try? input.close() }
        while let chunk = try input.read(upToCount: 1 << 20), !chunk.isEmpty {
            try Task.checkCancellation()
            try out.write(contentsOf: chunk)
        }
        try out.write(contentsOf: Data("\r\n--\(boundary)--\r\n".utf8))
    }
}
