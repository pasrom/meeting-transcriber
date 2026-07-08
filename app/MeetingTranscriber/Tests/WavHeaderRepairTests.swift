@preconcurrency import AVFoundation
@testable import MeetingTranscriber
import XCTest

/// Issue #379 secondary bug: a crash mid-recording leaves the WAV header
/// unfinalized (`data` size = 0, `RIFF` size = placeholder), so the file reads
/// as 0 frames even though the PCM is intact. These tests write a real WAV via
/// AVAudioFile (the app's exact format, incl. the JUNK chunk), corrupt the two
/// size fields to mimic the crash, and assert `WavHeaderRepair` makes it
/// readable again. Fully deterministic — pure byte structure, no hardware.
final class WavHeaderRepairTests: XCTestCase {
    private func tempURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("wavrepair-\(UUID().uuidString).wav")
    }

    /// Writes a real 16 kHz mono Int16 WAV via AVAudioFile and returns its URL
    /// + finalized frame count. The AVAudioFile closes (finalizes the header)
    /// when it goes out of scope at the end of this function.
    private func writeFinalizedWav(seconds: Double, at target: URL? = nil) throws -> (url: URL, frames: AVAudioFramePosition) {
        let url = target ?? tempURL()
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 16000.0,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
        let frames = AVAudioFrameCount(16000.0 * seconds)
        let length: AVAudioFramePosition
        do {
            let file = try AVAudioFile(forWriting: url, settings: settings)
            let buffer = try XCTUnwrap(
                AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frames),
            )
            buffer.frameLength = frames
            if let ch = buffer.floatChannelData {
                for i in 0 ..< Int(frames) {
                    ch[0][i] = Float(i % 100) / 100.0
                }
            }
            try file.write(from: buffer)
            length = file.length
        } // `file` deallocs here → header finalized on disk
        return (url, length)
    }

    /// Mimic the crash: zero the `data` chunk size and set the `RIFF` size to a
    /// placeholder. Locates the `data` marker by search (the crafted PCM ramp
    /// never contains the ASCII "data"), independent of WavHeaderRepair's parse.
    private func corruptHeader(at url: URL) throws {
        var data = try Data(contentsOf: url)
        let dataMarker = Data("data".utf8)
        let r = try XCTUnwrap(data.range(of: dataMarker), "no data chunk found")
        let sizeOffset = r.upperBound
        data.replaceSubrange(sizeOffset ..< sizeOffset + 4, with: [0, 0, 0, 0]) // data size = 0
        data.replaceSubrange(4 ..< 8, with: [4, 0, 0, 0]) // RIFF size = placeholder
        try data.write(to: url)
    }

    /// Frames AVAudioFile can read, or 0 if it can't even open the file — an
    /// unfinalized header may make AVAudioFile throw rather than report 0 frames.
    private func readableFrames(_ url: URL) -> AVAudioFramePosition {
        (try? AVAudioFile(forReading: url))?.length ?? 0
    }

    func testRepairsUnfinalizedWavSoItReadsAgain() throws {
        let (url, _) = try writeFinalizedWav(seconds: 0.5)
        defer { try? FileManager.default.removeItem(at: url) }
        // Baseline against the finalized file's READ-BACK length (the true
        // on-disk frame count the repair must restore), not the write-side
        // file.length.
        let originalFrames = readableFrames(url)
        XCTAssertGreaterThan(originalFrames, 0, "baseline WAV should have frames")

        try corruptHeader(at: url)
        XCTAssertEqual(readableFrames(url), 0, "corruption should make the file unreadable/empty (the bug)")

        let repaired = try WavHeaderRepair.repairIfNeeded(at: url)
        XCTAssertTrue(repaired, "should report it repaired an unfinalized file")
        XCTAssertEqual(readableFrames(url), originalFrames, "repaired file should read the original frames")
    }

    func testLeavesAlreadyFinalizedWavUntouched() throws {
        let (url, _) = try writeFinalizedWav(seconds: 0.3)
        defer { try? FileManager.default.removeItem(at: url) }
        let before = try Data(contentsOf: url)

        let repaired = try WavHeaderRepair.repairIfNeeded(at: url)
        XCTAssertFalse(repaired, "a finalized WAV must not be reported as repaired")
        XCTAssertEqual(try Data(contentsOf: url), before, "a finalized WAV must be left byte-for-byte unchanged")
    }

    func testIgnoresNonWavFile() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let junk = Data("not a wav file at all, just some bytes".utf8)
        try junk.write(to: url)

        let repaired = try WavHeaderRepair.repairIfNeeded(at: url)
        XCTAssertFalse(repaired, "a non-WAV file must not be touched")
        XCTAssertEqual(try Data(contentsOf: url), junk, "a non-WAV file must be left unchanged")
    }

    func testRepairUnfinalizedScansDirAndFixesOnlyBrokenWavs() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("wavrepairdir-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let brokenURL = dir.appendingPathComponent("crashed_mic.wav")
        _ = try writeFinalizedWav(seconds: 0.4, at: brokenURL)
        try corruptHeader(at: brokenURL)
        let validURL = dir.appendingPathComponent("clean_mix.wav")
        _ = try writeFinalizedWav(seconds: 0.4, at: validURL)
        let validBefore = try Data(contentsOf: validURL)
        try Data("junk".utf8).write(to: dir.appendingPathComponent("notes.txt"))

        XCTAssertEqual(readableFrames(brokenURL), 0, "broken WAV starts unreadable")

        // minAge: 0 disables the live-file guard so this freshly-written
        // fixture exercises the repair logic itself (the guard has its own test).
        let count = WavHeaderRepair.repairUnfinalized(in: dir, minAge: 0)

        XCTAssertEqual(count, 1, "only the one unfinalized WAV should be repaired")
        XCTAssertGreaterThan(readableFrames(brokenURL), 0, "the crashed WAV is readable after the dir pass")
        XCTAssertEqual(try Data(contentsOf: validURL), validBefore, "a finalized WAV must be left unchanged")
    }

    func testRepairUnfinalizedSkipsRecentlyModifiedWavs() throws {
        // A WAV still being written by a live recording legitimately has a zero
        // data size. The launch scan must not "repair" it: stamping a partial
        // size now erases the 0-size signature, so a later crash of the same
        // file could never be recovered (the ==0 guard would reject it).
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("wavrepairfresh-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let liveURL = dir.appendingPathComponent("inprogress_mic.wav")
        _ = try writeFinalizedWav(seconds: 0.4, at: liveURL)
        try corruptHeader(at: liveURL) // unfinalized + just written → recent mtime

        // Default 30 s guard: a file modified moments ago is treated as live.
        let count = WavHeaderRepair.repairUnfinalized(in: dir)

        XCTAssertEqual(count, 0, "a recently-modified (possibly live) WAV must be skipped")
        XCTAssertEqual(readableFrames(liveURL), 0, "the live WAV's header must be left untouched")
    }

    // MARK: - Chunk-walk edges (byte-level, no AVAudioFile)

    private func fourCC(_ s: String) -> Data {
        Data(s.utf8)
    }

    private func leU32(_ v: UInt32) -> Data {
        withUnsafeBytes(of: v.littleEndian) { Data($0) }
    }

    private func readU32LE(_ d: Data, _ offset: Int) -> UInt32 {
        d.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self) }
    }

    /// A chunk with an ODD payload size is padded to an even boundary on disk
    /// (RIFF spec). The walk must add that pad byte via `size & 1`, or the next
    /// read lands one byte early — mid-chunk — and never finds `data`. Craft an
    /// odd-sized prelude chunk followed by an unfinalized `data` chunk and assert
    /// the repair still finds and rewrites it.
    func testRepairWalksPastOddSizedChunkToDataChunk() throws {
        var wav = Data()
        wav.append(fourCC("RIFF"))
        wav.append(leU32(4)) // placeholder RIFF size (unfinalized)
        wav.append(fourCC("WAVE"))
        // Odd-sized prelude chunk: 3-byte payload → 1 pad byte on disk.
        wav.append(fourCC("JUNK"))
        wav.append(leU32(3))
        wav.append(Data([0xAA, 0xBB, 0xCC]))
        wav.append(Data([0x00])) // pad to even length
        // Unfinalized data chunk: size 0 is the killed-writer signature.
        wav.append(fourCC("data"))
        wav.append(leU32(0))
        let pcm = Data([1, 2, 3, 4, 5, 6, 7, 8])
        wav.append(pcm)

        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        try wav.write(to: url)

        let repaired = try WavHeaderRepair.repairIfNeeded(at: url)
        XCTAssertTrue(repaired, "must walk past the padded odd-sized chunk and repair the data size")

        let out = try Data(contentsOf: url)
        let dataRange = try XCTUnwrap(out.range(of: fourCC("data")), "data chunk id must survive the rewrite")
        XCTAssertEqual(
            readU32LE(out, dataRange.upperBound), UInt32(pcm.count),
            "data size rewritten to the actual PCM byte count",
        )
        XCTAssertEqual(
            readU32LE(out, 4), UInt32(out.count - 8),
            "RIFF size rewritten to fileSize - 8",
        )
    }

    /// No `data` chunk at all → the walk exhausts and `repairIfNeeded` must bail
    /// without touching the file.
    func testReturnsFalseWhenNoDataChunkPresent() throws {
        var wav = Data()
        wav.append(fourCC("RIFF"))
        wav.append(leU32(4))
        wav.append(fourCC("WAVE"))
        wav.append(fourCC("fmt "))
        wav.append(leU32(4))
        wav.append(Data([0, 0, 0, 0]))

        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        try wav.write(to: url)
        let before = try Data(contentsOf: url)

        XCTAssertFalse(try WavHeaderRepair.repairIfNeeded(at: url), "no data chunk → nothing to repair")
        XCTAssertEqual(try Data(contentsOf: url), before, "file must be untouched when no data chunk is found")
    }
}
