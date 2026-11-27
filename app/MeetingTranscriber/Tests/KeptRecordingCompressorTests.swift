import AVFoundation
@testable import MeetingTranscriber
import os
import XCTest

/// The FLAC copy of a kept track: it must decode to exactly the samples of
/// the WAV it is made from, be native FLAC, be on the disk before `prepare`
/// returns, and leave nothing behind whenever it is not made.
final class KeptRecordingCompressorTests: XCTestCase {
    // swiftlint:disable:previous balanced_xctest_lifecycle
    // swiftlint:disable:next implicitly_unwrapped_optional
    private var tmpDir: URL!

    override func setUp() async throws {
        try await super.setUp()
        tmpDir = try makeTempDirectory(prefix: "kept-recording-compressor")
    }

    // MARK: - Fixtures

    /// Every Int16 value at least once (both extremes included), then a
    /// noisy tone, so the round trip is checked on the full sample range and
    /// on signal that resembles speech more than a sweep does.
    private static func syntheticSamples(seconds: Int = 6) -> [Float] {
        var samples = (Int(Int16.min) ... Int(Int16.max)).map { Float($0) / 32768 }
        var seed: UInt32 = 7
        for index in 0 ..< seconds * AudioConstants.targetSampleRate {
            seed = seed &* 1_664_525 &+ 1_013_904_223
            let noise = Float(Int32(bitPattern: seed) >> 20) / 2048
            let value = 9000 * sin(Float(index) * 0.031) + 400 * noise
            samples.append(Float(Int16(clamping: Int(value))) / 32768)
        }
        return samples
    }

    private func writeWAV(_ name: String, samples: [Float] = syntheticSamples()) throws -> URL {
        let url = tmpDir.appendingPathComponent(name)
        try AudioMixer.saveWAV(samples: samples, sampleRate: AudioConstants.targetSampleRate, url: url)
        return url
    }

    /// Read in a loop to the last frame (a single read of a long file can
    /// return short).
    private static func int16Samples(of url: URL) throws -> [Int16] {
        let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatInt16, interleaved: true)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 65536))
        var samples: [Int16] = []
        while file.framePosition < file.length {
            try file.read(into: buffer)
            guard buffer.frameLength > 0 else { break }
            let data = try XCTUnwrap(buffer.int16ChannelData)
            samples += UnsafeBufferPointer(start: data[0], count: Int(buffer.frameLength))
        }
        XCTAssertEqual(samples.count, Int(file.length), "the file reports \(file.length) frames")
        return samples
    }

    /// A three-second 24-bit mono WAV of noise over the full 24-bit range,
    /// with the sample at `changed` replaced when given.
    private func write24BitWAV(_ name: String, changed: Int? = nil) throws -> URL {
        let url = tmpDir.appendingPathComponent(name)
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: AudioConstants.targetSampleRate,
            AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 24,
            AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false,
        ]
        // Scoped, so the writer has closed the file when this returns.
        do {
            let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatInt32, interleaved: false)
            let frames = AVAudioFrameCount(3 * AudioConstants.targetSampleRate)
            let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frames))
            buffer.frameLength = frames
            let data = try XCTUnwrap(buffer.int32ChannelData)[0]
            var seed: UInt32 = 11
            for index in 0 ..< Int(frames) {
                seed = seed &* 1_664_525 &+ 1_013_904_223
                // The top 24 bits carry the sample; the low byte is zero.
                data[index] = Int32(bitPattern: seed & 0xFFFF_FF00)
            }
            if let changed { data[changed] = data[changed] &+ 0x100 }
            try file.write(from: buffer)
        }
        return url
    }

    /// The bits per sample in a native FLAC file's STREAMINFO block: after
    /// the `fLaC` marker comes the first metadata block's 4-byte header, then
    /// STREAMINFO, whose bytes 10 to 13 hold 20 bits of sample rate, 3 of
    /// channels minus one and 5 of bits per sample minus one.
    private static func flacBitsPerSample(of url: URL) throws -> Int {
        let bytes = try [UInt8](XCTUnwrap(FileHandle(forReadingFrom: url).read(upToCount: 42)))
        XCTAssertEqual(Data(bytes.prefix(4)), Data("fLaC".utf8))
        XCTAssertEqual(bytes[4] & 0x7F, 0, "the first metadata block is STREAMINFO")
        let field = 8 + 10
        return Int((bytes[field + 2] & 0x01) << 4 | bytes[field + 3] >> 4) + 1
    }

    private func names() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: tmpDir.path).sorted()
    }

    private func partial(for wav: URL) throws -> URL {
        try KeptRecordingCompressor.partialURL(for: XCTUnwrap(KeptRecordingCompressor.compressedURL(for: wav)))
    }

    // MARK: - Names

    func testThePartialIsHiddenEndsInFLACAndIsNoTrack() throws {
        let wav = tmpDir.appendingPathComponent("20270115_1200_weekly_sync_ab12cd34_app.wav")
        let flac = try XCTUnwrap(KeptRecordingCompressor.compressedURL(for: wav))
        let partial = KeptRecordingCompressor.partialURL(for: flac)

        XCTAssertEqual(flac.lastPathComponent, "20270115_1200_weekly_sync_ab12cd34_app.flac")
        XCTAssertEqual(partial.lastPathComponent, ".20270115_1200_weekly_sync_ab12cd34_app.partial.flac")
        XCTAssertEqual(partial.deletingLastPathComponent(), wav.deletingLastPathComponent())
        XCTAssertNil(RecordingFileSuffix.keptTrack(of: partial.lastPathComponent))
        XCTAssertNil(KeptRecordingCompressor.compressedURL(for: flac), "a FLAC is no WAV to compress")
    }

    // MARK: - Round trip

    func testTheCopyDecodesToExactlyTheSamplesAndIsNativeFLAC() throws {
        let wav = try writeWAV("meeting_app.wav")
        let partial = try partial(for: wav)

        try KeptRecordingCompressor().prepare(source: wav, partial: partial)

        let original = try Self.int16Samples(of: wav)
        XCTAssertGreaterThan(original.count, 65536, "test premise: more than one chunk, every Int16 value")
        XCTAssertEqual(try Self.int16Samples(of: partial), original)
        let header = try FileHandle(forReadingFrom: partial).read(upToCount: 4)
        XCTAssertEqual(header, Data("fLaC".utf8), "a native FLAC stream, not FLAC inside a CAF")
        XCTAssertTrue(FileManager.default.fileExists(atPath: wav.path), "prepare never touches its source")
    }

    /// A 16-bit track becomes a 16-bit FLAC: written from 32-bit buffers the
    /// encoder stores 24 bits a sample whatever the bit depth hint says,
    /// which costs space and says nothing about the recording.
    func testA16BitTrackIsWrittenAs16BitFLAC() throws {
        let wav = try writeWAV("meeting_mix.wav")
        let partial = try partial(for: wav)

        try KeptRecordingCompressor().prepare(source: wav, partial: partial)

        XCTAssertEqual(try Self.flacBitsPerSample(of: partial), 16)
    }

    /// A 24-bit track keeps its 24 bits, and its samples, through the copy.
    func testA24BitTrackIsWrittenAs24BitFLACAndRoundTrips() throws {
        let wav = try write24BitWAV("meeting_mix.wav")
        let partial = try partial(for: wav)

        try KeptRecordingCompressor().prepare(source: wav, partial: partial)

        XCTAssertEqual(try Self.flacBitsPerSample(of: partial), 24)
        XCTAssertNoThrow(try KeptRecordingCompressor().verify(partial, matches: wav))
    }

    /// The verify catches a copy of other samples for a 24-bit track too,
    /// down to one step in the lowest of its 24 bits.
    func testAMismatchIn24BitSamplesIsCaught() throws {
        let wav = try write24BitWAV("meeting_mix.wav")
        let other = try write24BitWAV("other_mix.wav", changed: 20000)
        let copy = tmpDir.appendingPathComponent("copy.flac")
        try KeptRecordingCompressor().prepare(source: other, partial: copy)

        XCTAssertThrowsError(try KeptRecordingCompressor().verify(copy, matches: wav)) { error in
            XCTAssertEqual(error as? KeptRecordingCompressor.Failure, .mismatch)
        }
    }

    /// The repository's speech fixture, 16 kHz mono Int16 like a kept track.
    func testTheSpeechFixtureRoundTripsAndShrinks() throws {
        let wav = tmpDir.appendingPathComponent("two_speakers_de_mix.wav")
        try FileManager.default.copyItem(at: fixtureURL(), to: wav)
        let partial = try partial(for: wav)

        try KeptRecordingCompressor().prepare(source: wav, partial: partial)

        XCTAssertEqual(try Self.int16Samples(of: partial), try Self.int16Samples(of: wav))
        let wavSize = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: wav.path)[.size] as? Int)
        let flacSize = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: partial.path)[.size] as? Int)
        XCTAssertLessThan(flacSize, wavSize)
    }

    /// The app's own loader reads a FLAC track to its last frame, as from the WAV.
    func testTheAppLoaderReadsEveryFrameOfAFLACTrack() throws {
        let wav = try writeWAV("loader_mix.wav", samples: Self.syntheticSamples(seconds: 60))
        let partial = try partial(for: wav)
        try KeptRecordingCompressor().prepare(source: wav, partial: partial)

        let fromWAV = try AudioMixer.loadAudioFileAsFloat32(url: wav)
        let fromFLAC = try AudioMixer.loadAudioFileAsFloat32(url: partial)

        XCTAssertEqual(fromFLAC.count, fromWAV.count)
        // Not XCTAssertEqual: its failure message prints both arrays whole.
        XCTAssertTrue(fromFLAC == fromWAV, "the FLAC track decodes to other samples") // swiftlint:disable:this xct_specific_matcher
    }

    func testTheCopyIsOwnerOnlyAndKeepsTheSourceDates() throws {
        let wav = try writeWAV("meeting_mic.wav")
        let stamp = Date(timeIntervalSince1970: 1_780_000_000)
        try FileManager.default.setAttributes([.modificationDate: stamp], ofItemAtPath: wav.path)
        let partial = try partial(for: wav)

        try KeptRecordingCompressor().prepare(source: wav, partial: partial)

        let attributes = try FileManager.default.attributesOfItem(atPath: partial.path)
        let mode = try XCTUnwrap(attributes[.posixPermissions] as? Int)
        XCTAssertEqual(mode & 0o077, 0, "meeting audio stays private to its owner")
        XCTAssertEqual(attributes[.modificationDate] as? Date, stamp)
    }

    // MARK: - Refusals and failures: the source stays, no partial

    /// Rewrite the `data` chunk size of a WAV to declare `frames` frames of
    /// 16-bit mono, whatever the file holds.
    private func setDataChunkFrames(_ frames: UInt32, in url: URL) throws {
        var bytes = try Data(contentsOf: url)
        let marker = try XCTUnwrap(bytes.range(of: Data("data".utf8)), "no data chunk")
        withUnsafeBytes(of: (frames * 2).littleEndian) { bytes.replaceSubrange(marker.upperBound ..< marker.upperBound + 4, with: $0) }
        try bytes.write(to: url)
    }

    /// A `data` chunk that states half of what the file holds decodes,
    /// compares and compresses as the shorter recording; the WAV holds the
    /// rest, so it is refused before anything is written.
    func testAHeaderThatCountsFewerFramesThanTheFileHoldsIsRefused() throws {
        let wav = try writeWAV("short_header_mix.wav", samples: [Float](repeating: 0.1, count: 160_000))
        try setDataChunkFrames(80000, in: wav)
        XCTAssertEqual(try AVAudioFile(forReading: wav).length, 80000, "test premise: the header now counts half")

        XCTAssertThrowsError(try KeptRecordingCompressor().prepare(source: wav, partial: partial(for: wav))) { error in
            XCTAssertEqual(error as? KeptRecordingCompressor.Failure, .lengthDisagreesWithFileSize)
        }
        XCTAssertEqual(try names(), ["short_header_mix.wav"])
    }

    /// Audio after a short `data` chunk that happens to start like a chunk
    /// header (a readable name, a size running past the end) is still audio
    /// the header leaves out: refused.
    func testAudioAfterAShortDataChunkThatLooksLikeAChunkIsRefused() throws {
        let wav = try writeWAV("lookalike_mix.wav", samples: [Float](repeating: 0.1, count: 160_000))
        try setDataChunkFrames(80000, in: wav)
        var bytes = try Data(contentsOf: wav)
        let audioStart = try XCTUnwrap(bytes.range(of: Data("data".utf8))).upperBound + 4
        var lookalike = Data("ABCD".utf8)
        withUnsafeBytes(of: UInt32(0x7FFF_FFF0).littleEndian) { lookalike += $0 }
        bytes.replaceSubrange(audioStart + 160_000 ..< audioStart + 160_008, with: lookalike)
        try bytes.write(to: wav)

        XCTAssertThrowsError(try KeptRecordingCompressor().prepare(source: wav, partial: partial(for: wav))) { error in
            XCTAssertEqual(error as? KeptRecordingCompressor.Failure, .lengthDisagreesWithFileSize)
        }
    }

    /// The reverse, a header claiming more audio than the file holds (a
    /// write cut off): refused as well, the WAV left as it is.
    func testAHeaderThatCountsMoreFramesThanTheFileHoldsIsRefused() throws {
        let wav = try writeWAV("long_header_mix.wav", samples: [Float](repeating: 0.1, count: 80000))
        try setDataChunkFrames(160_000, in: wav)

        XCTAssertThrowsError(try KeptRecordingCompressor().prepare(source: wav, partial: partial(for: wav))) { error in
            XCTAssertEqual(error as? KeptRecordingCompressor.Failure, .lengthDisagreesWithFileSize)
        }
        XCTAssertEqual(try names(), ["long_header_mix.wav"])
    }

    /// Metadata of any size, after the audio too, is no reason to refuse: the
    /// chunks still account for the whole file.
    func testALargeMetadataChunkAfterTheAudioIsAccepted() throws {
        let wav = try writeWAV("tagged_mix.wav", samples: [Float](repeating: 0.1, count: 16000))
        var bytes = try Data(contentsOf: wav)
        let payload = Data(repeating: 0x41, count: 20000)
        bytes += Data("LIST".utf8)
        withUnsafeBytes(of: UInt32(payload.count).littleEndian) { bytes += $0 }
        bytes += payload
        withUnsafeBytes(of: UInt32(bytes.count - 8).littleEndian) { bytes.replaceSubrange(4 ..< 8, with: $0) }
        try bytes.write(to: wav)
        let partial = try partial(for: wav)

        try KeptRecordingCompressor().prepare(source: wav, partial: partial)

        XCTAssertEqual(try AVAudioFile(forReading: partial).length, 16000)
    }

    func testAFloatWAVIsRefusedAndLeavesNothingBehind() throws {
        let float = tmpDir.appendingPathComponent("float_mix.wav")
        try FileManager.default.moveItem(at: createTestAudioFile(in: tmpDir), to: float)

        XCTAssertThrowsError(try KeptRecordingCompressor().prepare(source: float, partial: partial(for: float))) { error in
            XCTAssertEqual(error as? KeptRecordingCompressor.Failure, .notIntegerPCM)
        }
        XCTAssertEqual(try names(), ["float_mix.wav"])
    }

    /// The name decides the container: a partial not ending in `.flac` gets
    /// FLAC inside a CAF from the same call, which `prepare` refuses.
    func testAPartialNameNotEndingInFLACIsRefused() throws {
        let wav = try writeWAV("meeting_mix.wav")
        let wrong = tmpDir.appendingPathComponent(".meeting_mix.flac.partial")

        XCTAssertThrowsError(try KeptRecordingCompressor().prepare(source: wav, partial: wrong)) { error in
            XCTAssertEqual(error as? KeptRecordingCompressor.Failure, .notNativeFLAC)
        }
        XCTAssertEqual(try names(), ["meeting_mix.wav"])
    }

    /// The copy is changed between the write and the verify; the verify must
    /// catch it.
    func testAMismatchLeavesNoCopyAndTheSource() throws {
        let wav = try writeWAV("meeting_mix.wav")
        var compressor = KeptRecordingCompressor()
        compressor.afterWrite = { partial in
            // Replace the copy with a valid FLAC of other samples.
            let other = partial.deletingLastPathComponent().appendingPathComponent("other.wav")
            var samples = Self.syntheticSamples()
            samples[100_000] = 0.5
            try AudioMixer.saveWAV(samples: samples, sampleRate: AudioConstants.targetSampleRate, url: other)
            try FileManager.default.removeItem(at: partial)
            try KeptRecordingCompressor().prepare(source: other, partial: partial)
            try FileManager.default.removeItem(at: other)
        }

        XCTAssertThrowsError(try compressor.prepare(source: wav, partial: partial(for: wav))) { error in
            XCTAssertEqual(error as? KeptRecordingCompressor.Failure, .mismatch)
        }
        XCTAssertEqual(try names(), ["meeting_mix.wav"])
    }

    /// A read of the copy may return fewer frames than asked without being at
    /// the end. Compared chunk by chunk, that is a false mismatch; by
    /// position it is the same stream.
    func testAShortDecodeReadIsNotAMismatch() throws {
        let wav = try writeWAV("meeting_mix.wav")
        var compressor = KeptRecordingCompressor()
        compressor.readCopy = { file, buffer, count in try file.read(into: buffer, frameCount: count / 2 + 1) }

        XCTAssertNoThrow(try compressor.prepare(source: wav, partial: partial(for: wav)))
    }

    func testCancellationLeavesNoCopy() async throws {
        let wav = try writeWAV("meeting_mix.wav")
        let partial = try partial(for: wav)
        let task = Task.detached {
            withUnsafeCurrentTask { $0?.cancel() }
            try KeptRecordingCompressor().prepare(source: wav, partial: partial)
        }

        do {
            try await task.value
            XCTFail("a cancelled prepare returned normally")
        } catch {
            XCTAssertTrue(error is CancellationError, "\(error)")
        }
        XCTAssertEqual(try names(), ["meeting_mix.wav"])
    }

    func testALeftoverPartialIsReplaced() throws {
        let wav = try writeWAV("meeting_mix.wav")
        let partial = try partial(for: wav)
        try Data("half a copy from a run that was cut off".utf8).write(to: partial)

        try KeptRecordingCompressor().prepare(source: wav, partial: partial)

        XCTAssertEqual(try Self.int16Samples(of: partial), try Self.int16Samples(of: wav))
    }

    /// A write that fails partway (a full disk) leaves no partial.
    func testAFullDiskLeavesNoPartial() throws {
        let wav = try writeWAV("meeting_mix.wav")
        var compressor = KeptRecordingCompressor()
        compressor.afterWrite = { _ in throw POSIXError(.ENOSPC) }

        XCTAssertThrowsError(try compressor.prepare(source: wav, partial: partial(for: wav))) { error in
            XCTAssertEqual((error as? POSIXError)?.code, .ENOSPC)
        }
        XCTAssertEqual(try names(), ["meeting_mix.wav"])
    }

    /// The sync runs on the verified copy, before `prepare` returns.
    func testTheCopyIsSyncedBeforePrepareReturns() throws {
        let wav = try writeWAV("meeting_mix.wav")
        let partial = try partial(for: wav)
        let synced = OSAllocatedUnfairLock<[String]>(initialState: [])
        var compressor = KeptRecordingCompressor()
        compressor.sync = { url in
            synced.withLock { $0.append(url.lastPathComponent) }
            XCTAssertTrue(KeptRecordingCompressor.isNativeFLAC(url), "synced before the copy was written")
            try KeptRecordingCompressor.fullSync(url)
        }

        try compressor.prepare(source: wav, partial: partial)

        XCTAssertEqual(synced.withLock { $0 }, [partial.lastPathComponent])
    }

    func testAFailedSyncFailsThePrepare() throws {
        let wav = try writeWAV("meeting_mix.wav")
        var compressor = KeptRecordingCompressor()
        compressor.sync = { _ in throw KeptRecordingCompressor.Failure.syncFailed }

        XCTAssertThrowsError(try compressor.prepare(source: wav, partial: partial(for: wav))) { error in
            XCTAssertEqual(error as? KeptRecordingCompressor.Failure, .syncFailed)
        }
        XCTAssertEqual(try names(), ["meeting_mix.wav"])
    }

    func testTheRealSyncWorksOnAFileAndAFolder() throws {
        let wav = try writeWAV("meeting_mix.wav")
        XCTAssertNoThrow(try KeptRecordingCompressor.fullSync(wav))
        XCTAssertTrue(KeptRecordingCompressor.syncFolder(tmpDir))
        XCTAssertThrowsError(try KeptRecordingCompressor.fullSync(tmpDir.appendingPathComponent("missing")))
    }

    // MARK: - Probe

    func testTheProbeFindsFLACOnThisMac() {
        XCTAssertEqual(KeptRecordingCodecProbe.run(in: tmpDir), .available)
        XCTAssertEqual(try names(), [], "the probe leaves its folder behind")
    }

    /// A full volume says nothing about the codec, and `AVAudioFile` reports
    /// it in its own domain (-40, measured on macOS 27): no answer, so jobs
    /// are still marked for a later launch.
    func testAFullVolumeLeavesTheAnswerOpen() throws {
        let status = KeptRecordingCodecProbe.run(in: tmpDir) { _, _ in
            throw NSError(domain: "com.apple.coreaudio.avfaudio", code: -40)
        }

        XCTAssertEqual(status, .unknown)
        XCTAssertEqual(try names(), [])
    }

    /// The error `AVAudioFile` throws for a format it cannot write (`'fmt?'`,
    /// measured on macOS 27) is an answer: no FLAC here.
    func testAnUnsupportedFormatReportsUnavailable() {
        let status = KeptRecordingCodecProbe.run(in: tmpDir) { _, _ in
            throw NSError(domain: "com.apple.coreaudio.avfaudio", code: 1_718_449_215)
        }

        XCTAssertEqual(status, .unavailable(reason: "com.apple.coreaudio.avfaudio 1718449215"))
    }

    func testAFailingEncoderReportsUnavailableWithAReason() throws {
        let status = KeptRecordingCodecProbe.run(in: tmpDir) { _, _ in throw KeptRecordingCompressor.Failure.notNativeFLAC }

        XCTAssertEqual(status, .unavailable(reason: "notNativeFLAC"))
        XCTAssertEqual(status.codecName, "none")
        XCTAssertEqual(try names(), [])
    }

    /// An encoder that "succeeds" without writing native FLAC is no FLAC.
    func testAnEncoderThatWritesNoNativeFLACIsUnavailable() {
        let status = KeptRecordingCodecProbe.run(in: tmpDir) { _, copy in try Data("caff".utf8).write(to: copy) }

        XCTAssertEqual(status, .unavailable(reason: "not native FLAC"))
    }
}
