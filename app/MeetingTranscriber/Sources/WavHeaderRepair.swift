import Foundation

/// Repairs an unfinalized WAV — one whose `RIFF`/`data` chunk sizes were left
/// at placeholder values because the writer was killed before it closed the
/// file (issue #379 secondary bug: a crash mid-recording leaves the header
/// unfinalized, so the file reads as 0 frames even though the PCM is intact).
/// Rewrites the two size fields from the actual on-disk size so the audio is
/// readable again.
enum WavHeaderRepair {
    /// Repairs `url` if its header looks unfinalized. Returns true if it
    /// rewrote the file, false if the header was already valid (or the file
    /// isn't a WAV we can repair). Operates at the byte level, so it works even
    /// when AVAudioFile can't open the corrupted file.
    @discardableResult
    static func repairIfNeeded(at url: URL) throws -> Bool {
        let handle = try FileHandle(forUpdating: url)
        defer { try? handle.close() }

        let fileSize = try Int(handle.seekToEnd())
        guard fileSize >= 12 else { return false }

        try handle.seek(toOffset: 0)
        guard let riffHeader = try handle.read(upToCount: 12), riffHeader.count == 12,
              isFourCC(riffHeader, 0, "RIFF"), isFourCC(riffHeader, 8, "WAVE")
        else { return false }

        // Walk the chunk list (JUNK, fmt, …) by id+size until the `data` chunk.
        // We stop AT `data` before trusting its (possibly zero) size, so an
        // unfinalized data size doesn't derail the walk.
        var offset = 12
        var dataChunkOffset: Int?
        while offset + 8 <= fileSize {
            try handle.seek(toOffset: UInt64(offset))
            guard let chunk = try handle.read(upToCount: 8), chunk.count == 8 else { break }
            if isFourCC(chunk, 0, "data") { dataChunkOffset = offset; break }
            let size = Int(u32(chunk, 4))
            offset += 8 + size + (size & 1) // chunks are padded to an even length
        }
        guard let dataOffset = dataChunkOffset else { return false }

        let pcmStart = dataOffset + 8
        let actualDataSize = fileSize - pcmStart
        guard actualDataSize > 0, actualDataSize <= Int(UInt32.max) else { return false }
        let correctRiffSize = fileSize - 8

        try handle.seek(toOffset: UInt64(dataOffset + 4))
        let declaredDataSize = try Int(u32(handle.read(upToCount: 4) ?? Data(), 0))

        // Only the unfinalized signature (data size left at 0 by a killed
        // writer) is safe to repair. A non-zero size means the writer finalized
        // the file — don't second-guess it (it may have trailing chunks that
        // would make a filesize-derived size wrong, corrupting a valid file).
        guard declaredDataSize == 0 else { return false }

        try handle.seek(toOffset: UInt64(dataOffset + 4))
        try handle.write(contentsOf: leBytes(UInt32(actualDataSize)))
        try handle.seek(toOffset: 4)
        try handle.write(contentsOf: leBytes(UInt32(correctRiffSize)))
        return true
    }

    /// Scans `dir` (non-recursively) for `*.wav` files and repairs any with an
    /// unfinalized header. Returns the number actually repaired. Called at
    /// launch to rescue recordings whose writer was killed mid-stream (#379).
    ///
    /// `minAge` skips a WAV still being written by an in-progress recording
    /// (recent mtime). A live track legitimately has a zero data size until it
    /// closes; stamping a partial size now would erase that 0-size signature,
    /// so a later crash of the same file could never be recovered (the `==0`
    /// guard in `repairIfNeeded` would reject it). The launch queue-build Task
    /// can fire right as a watch-started recording begins, so the window is
    /// real. Same guard as `recoverCrashedRecordings` / `cleanupTempFiles`.
    @discardableResult
    static func repairUnfinalized(in dir: URL, minAge: TimeInterval = 30) -> Int {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil,
        ) else { return 0 }
        let cutoff = Date().addingTimeInterval(-minAge)
        var repaired = 0
        for url in entries where url.pathExtension.lowercased() == "wav" {
            if let mtime = (try? fm.attributesOfItem(atPath: url.path)[.modificationDate]) as? Date,
               mtime > cutoff { continue }
            if (try? repairIfNeeded(at: url)) == true { repaired += 1 }
        }
        return repaired
    }

    private static func isFourCC(_ data: Data, _ offset: Int, _ cc: String) -> Bool {
        let start = data.startIndex + offset
        return data[start ..< start + 4].elementsEqual(cc.utf8)
    }

    private static func u32(_ data: Data, _ offset: Int) -> UInt32 {
        // WAV chunk sizes are little-endian; arm64/x86_64 are little-endian, so
        // an unaligned native load yields the value directly.
        data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self) }
    }

    private static func leBytes(_ value: UInt32) -> Data {
        withUnsafeBytes(of: value.littleEndian) { Data($0) }
    }
}
