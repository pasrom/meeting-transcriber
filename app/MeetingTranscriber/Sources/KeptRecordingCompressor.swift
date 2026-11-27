@preconcurrency import AVFoundation
import Foundation

/// Lossless FLAC copies of the tracks a finished recording keeps in the output
/// folder (`RecordingCompaction`).
///
/// Only for files at rest: capture, staging and crash recovery stay on WAV,
/// because a WAV cut off by a crash is repaired by rewriting its header
/// (`WavHeaderRepair`) and a cut-off FLAC stream is not.
///
/// `prepare` never touches its source and never writes the final name: it
/// writes a hidden partial beside the source, decodes it again and compares
/// every sample with the source, and flushes it to the disk. Putting it under
/// its final name, tracking it and removing the source is the caller's
/// sequence, because each of those steps needs the registry and the main actor.
///
/// FLAC holds integer samples only, so a source that is not integer PCM of at
/// most 24 bits is refused: the recorder writes 16-bit tracks, and anything else
/// would come back rounded.
struct KeptRecordingCompressor: Sendable {
    /// Why a copy was not made. Every case leaves the source as it is and no
    /// partial behind.
    enum Failure: Error, Equatable {
        /// The source is not integer PCM of at most 24 bits.
        case notIntegerPCM
        /// The copy does not decode to exactly the source's samples.
        case mismatch
        /// The copy was written in another container than native FLAC.
        /// `AVAudioFile` picks the container from the file name and, given a
        /// name that does not end in `.flac`, writes FLAC inside a CAF file
        /// without an error (measured on macOS 27).
        case notNativeFLAC
        /// Neither `F_FULLFSYNC` nor `fsync` succeeded on the copy, so nothing
        /// says it is on the disk before the source is removed.
        case syncFailed
        /// The audio the header declares does not account for the file's
        /// size: a `data` chunk that states fewer frames than the file holds
        /// would decode, compare and compress as the shorter recording, and
        /// removing the WAV would lose the rest.
        case lengthDisagreesWithFileSize
    }

    /// Reads up to `frameCount` frames from `file` into `buffer`. A read may
    /// return fewer frames than asked without being at the end of the file.
    typealias ChunkReader = @Sendable (AVAudioFile, AVAudioPCMBuffer, AVAudioFrameCount) throws -> Void

    /// How the copy is read back for the comparison. Injectable so a test can
    /// make it return short.
    var readCopy: ChunkReader = { file, buffer, count in try file.read(into: buffer, frameCount: count) }
    /// Runs between the write and the verify. A test corrupts the copy here.
    var afterWrite: @Sendable (URL) throws -> Void = { _ in }
    /// Flushes the copy to the disk; throws when that cannot be confirmed.
    var sync: @Sendable (URL) throws -> Void = { try Self.fullSync($0) }
    /// Frames per read, write and compare. 4 s at 16 kHz.
    var chunkFrames: AVAudioFrameCount = 65536

    /// The compressed name of a WAV track: `<stem>_mix.wav` becomes
    /// `<stem>_mix.flac` in the same folder. Nil for a name that is no WAV track.
    static func compressedURL(for wav: URL) -> URL? {
        guard let track = RecordingFileSuffix.keptTrack(
            of: wav.lastPathComponent, extensions: [RecordingFileSuffix.wavExtension],
        ) else { return nil }
        let name = track.stem + RecordingFileSuffix.kept(track.suffix, extension: RecordingFileSuffix.compressedExtension)
        return wav.deletingLastPathComponent().appendingPathComponent(name)
    }

    /// Where the copy of `destination` is written before it gets that name:
    /// `.<stem>_mix.partial.flac` beside it. Hidden, deterministic (a later
    /// attempt replaces what a cut-off one left) and still ending in `.flac`,
    /// which is what makes `AVAudioFile` write native FLAC; it does not end in
    /// a track suffix, so no reader takes it for a track.
    static func partialURL(for destination: URL) -> URL {
        let name = "." + destination.deletingPathExtension().lastPathComponent + partialSuffix
        return destination.deletingLastPathComponent().appendingPathComponent(name)
    }

    /// The end of every partial copy's name, which the sweep of leftovers
    /// matches together with the leading dot.
    static let partialSuffix = ".partial.flac"

    /// Encode `source` into `partial`, replacing a leftover there; check that
    /// it is native FLAC and decodes to exactly the samples of `source`; set
    /// it owner-only and give it the source's dates (both best effort: a
    /// volume without POSIX modes must not turn every track into a
    /// permanent WAV); and flush it to the disk. Throws `Failure`, a write or
    /// read error, or `CancellationError`; on every throw `partial` is gone.
    func prepare(source: URL, partial: URL) throws {
        let fm = FileManager.default
        try? fm.removeItem(at: partial)
        do {
            try encode(source, to: partial)
            try afterWrite(partial)
            guard Self.isNativeFLAC(partial) else { throw Failure.notNativeFLAC }
            try verify(partial, matches: source)
            try? fm.restrictToOwner(partial)
            if let attributes = try? fm.attributesOfItem(atPath: source.path) {
                let dates = attributes.filter { $0.key == .creationDate || $0.key == .modificationDate }
                try? fm.setAttributes(dates, ofItemAtPath: partial.path)
            }
            try sync(partial)
        } catch {
            try? fm.removeItem(at: partial)
            throw error
        }
    }

    /// Throws `lengthDisagreesWithFileSize` unless the header accounts for
    /// the whole file, chunk by chunk: a RIFF `WAVE` file whose chunks follow
    /// one another to the end of the file, each with a readable four-letter
    /// name, with one `data` chunk holding exactly `frames * bytesPerFrame`
    /// bytes. Metadata chunks of any size, before or after the audio, pass.
    /// Audio the `data` chunk leaves out does not: its bytes do not read as a
    /// chunk, or not as one ending where the file does.
    static func checkLength(of source: URL, frames: Int64, bytesPerFrame: Int64) throws {
        let failure = Failure.lengthDisagreesWithFileSize
        guard bytesPerFrame > 0 else { throw failure }
        // A file that cannot be opened now is a read error, which may pass,
        // not a verdict on its header.
        let handle = try FileHandle(forReadingFrom: source)
        defer { try? handle.close() }
        let size = try handle.seekToEnd()
        try handle.seek(toOffset: 0)
        guard let riff = try handle.read(upToCount: 12), riff.count == 12,
              riff.prefix(4) == Data("RIFF".utf8), riff.suffix(4) == Data("WAVE".utf8) else { throw failure }
        var offset: UInt64 = 12
        var dataBytes: UInt64?
        while offset < size {
            try handle.seek(toOffset: offset)
            guard let header = try handle.read(upToCount: 8), header.count == 8,
                  header.prefix(4).allSatisfy({ (0x20 ... 0x7E).contains($0) }) else { throw failure }
            let chunkSize = header.suffix(4).enumerated().reduce(UInt64(0)) { $0 | UInt64($1.element) << (8 * $1.offset) }
            if header.prefix(4) == Data("data".utf8) {
                guard dataBytes == nil else { throw failure }
                dataBytes = chunkSize
            }
            // Chunks are padded to an even size; a writer may leave out the
            // pad byte of the last one.
            offset += 8 + chunkSize + (chunkSize & 1)
        }
        guard offset == size || offset == size + 1, dataBytes == UInt64(frames * bytesPerFrame) else { throw failure }
    }

    /// Whether `url` starts with the native FLAC stream marker.
    static func isNativeFLAC(_ url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        return (try? handle.read(upToCount: 4)) == Data("fLaC".utf8)
    }

    private func encode(_ source: URL, to partial: URL) throws {
        let probe = try AVAudioFile(forReading: source)
        let fileFormat = probe.fileFormat
        let description = fileFormat.streamDescription.pointee
        let bits = Int(description.mBitsPerChannel)
        guard description.mFormatID == kAudioFormatLinearPCM,
              description.mFormatFlags & kAudioFormatFlagIsFloat == 0,
              (1 ... 24).contains(bits) else {
            throw Failure.notIntegerPCM
        }
        // The FLAC takes the bit depth of the buffers it is written from, not
        // the hint: from 32-bit buffers a 16-bit track is stored as 24 bits a
        // sample. Up to 16 bits it is read and written as 16-bit samples.
        let common: AVAudioCommonFormat = bits <= 16 ? .pcmFormatInt16 : .pcmFormatInt32
        let input = try AVAudioFile(forReading: source, commonFormat: common, interleaved: false)
        try Self.checkLength(of: source, frames: input.length, bytesPerFrame: Int64(description.mBytesPerFrame))
        let format = input.processingFormat
        // The writer flushes and closes when it goes away, so it must not
        // outlive this function: the verify and the sync read the file after.
        let output = try AVAudioFile(
            forWriting: partial,
            settings: [
                AVFormatIDKey: kAudioFormatFLAC,
                AVSampleRateKey: format.sampleRate,
                AVNumberOfChannelsKey: format.channelCount,
                AVEncoderBitDepthHintKey: bits,
            ],
            commonFormat: common,
            interleaved: false,
        )
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunkFrames) else {
            throw AudioMixerError.bufferCreationFailed
        }
        while input.framePosition < input.length {
            try Task.checkCancellation()
            try input.read(into: buffer, frameCount: chunkFrames)
            guard buffer.frameLength > 0 else { break }
            try output.write(from: buffer)
        }
    }

    /// Decode both files and compare every sample by its position in the
    /// stream, not chunk by chunk: a read may return fewer frames than asked,
    /// so two reads of the same size do not cover the same frames. Also
    /// compares the lengths, rates and channel counts.
    func verify(_ copy: URL, matches source: URL) throws {
        let original = try AVAudioFile(forReading: source, commonFormat: .pcmFormatInt32, interleaved: true)
        let decoded = try AVAudioFile(forReading: copy, commonFormat: .pcmFormatInt32, interleaved: true)
        guard original.length == decoded.length,
              original.processingFormat.channelCount == decoded.processingFormat.channelCount,
              original.processingFormat.sampleRate == decoded.processingFormat.sampleRate,
              let left = AVAudioPCMBuffer(pcmFormat: original.processingFormat, frameCapacity: chunkFrames),
              let right = AVAudioPCMBuffer(pcmFormat: decoded.processingFormat, frameCapacity: chunkFrames),
              let leftData = left.int32ChannelData?[0], let rightData = right.int32ChannelData?[0] else {
            throw Failure.mismatch
        }
        let channels = Int(original.processingFormat.channelCount)
        // Interleaved buffers, so a frame is `channels` samples in a row and
        // both streams are flat runs of samples. Offsets and counts in samples.
        var leftAt = 0, leftCount = 0, rightAt = 0, rightCount = 0
        var compared: Int64 = 0
        while true {
            try Task.checkCancellation()
            if leftAt == leftCount {
                leftCount = try Self.fill(left, from: original, channels: channels, chunk: chunkFrames) { file, buffer, count in
                    try file.read(into: buffer, frameCount: count)
                }
                leftAt = 0
            }
            if rightAt == rightCount {
                rightCount = try Self.fill(right, from: decoded, channels: channels, chunk: chunkFrames, reader: readCopy)
                rightAt = 0
            }
            if leftCount == 0, rightCount == 0 { break }
            // One stream ended before the other.
            guard leftCount > 0, rightCount > 0 else { throw Failure.mismatch }
            let run = min(leftCount - leftAt, rightCount - rightAt)
            guard memcmp(leftData + leftAt, rightData + rightAt, run * MemoryLayout<Int32>.size) == 0 else {
                throw Failure.mismatch
            }
            leftAt += run
            rightAt += run
            compared += Int64(run)
        }
        guard compared == original.length * Int64(channels) else { throw Failure.mismatch }
    }

    /// Read the next chunk of `file` into `buffer` and return how many samples
    /// it holds; 0 at the end of the file.
    private static func fill(
        _ buffer: AVAudioPCMBuffer, from file: AVAudioFile, channels: Int, chunk: AVAudioFrameCount, reader: ChunkReader,
    ) throws -> Int {
        guard file.framePosition < file.length else { return 0 }
        try reader(file, buffer, chunk)
        return Int(buffer.frameLength) * channels
    }

    // MARK: - Durability

    /// Flush `url` to the disk itself, not only to the drive's cache:
    /// `F_FULLFSYNC`, falling back to `fsync` where the volume refuses it.
    /// Throws `Failure.syncFailed` when neither succeeds.
    static func fullSync(_ url: URL) throws {
        guard syncDescriptor(of: url) else { throw Failure.syncFailed }
    }

    /// The same for a folder, so a rename in it is on the disk before the
    /// file it replaces is removed. Best effort: returns whether it worked.
    @discardableResult
    static func syncFolder(_ url: URL) -> Bool {
        syncDescriptor(of: url)
    }

    private static func syncDescriptor(of url: URL) -> Bool {
        let descriptor = url.withUnsafeFileSystemRepresentation { path in path.map { open($0, O_RDONLY) } ?? -1 }
        guard descriptor >= 0 else { return false }
        defer { close(descriptor) }
        return fcntl(descriptor, F_FULLFSYNC) != -1 || fsync(descriptor) == 0
    }
}
