// `@preconcurrency`: AVFoundation types lack Sendable annotations, the same
// gap SpeakerNamingView.swift guards.
@preconcurrency import AVFoundation

extension SpeakerNamingView {
    /// The samples of `start..<end` seconds of `audioPath`, or nil when that
    /// span holds no audio.
    ///
    /// Reads only the span's frames. The file is the meeting's 16 kHz mix, so
    /// decoding all of it to cut a few seconds cost about 230 MB of samples per
    /// click for an hour-long meeting. Takes the first channel; the mix is
    /// mono.
    nonisolated static func snippetSamples(
        audioPath: URL, start: TimeInterval, end: TimeInterval,
    ) throws -> (samples: [Float], sampleRate: Int)? {
        let file = try AVAudioFile(forReading: audioPath)
        let rate = Int(file.processingFormat.sampleRate)
        guard let range = sampleRange(start: start, end: end, sampleRate: rate, totalSamples: Int(file.length)),
              let buffer = AVAudioPCMBuffer(
                  pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(range.count),
              )
        else { return nil }
        file.framePosition = AVAudioFramePosition(range.lowerBound)
        try file.read(into: buffer, frameCount: AVAudioFrameCount(range.count))
        guard let channel = buffer.floatChannelData?[0] else { return nil }
        return (Array(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength))), rate)
    }

    /// The same span as a playable WAV held in memory.
    ///
    /// The WAV goes through a file because that is what `AudioMixer.saveWAV`
    /// writes, and the file is removed before this returns. The player plays
    /// the bytes, so nothing has to outlive playback, and no copy of the
    /// meeting's audio stays in `scratchDir`. It used to stay there for good,
    /// one file per speaker label.
    nonisolated static func snippetWAVData(
        audioPath: URL, start: TimeInterval, end: TimeInterval,
        scratchDir: URL = FileManager.default.temporaryDirectory,
    ) throws -> Data? {
        guard let (samples, rate) = try snippetSamples(audioPath: audioPath, start: start, end: end) else { return nil }
        let wav = scratchDir.appendingPathComponent("speaker_snippet_\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: wav) }
        try AudioMixer.saveWAV(samples: samples, sampleRate: rate, url: wav)
        return try Data(contentsOf: wav)
    }
}
