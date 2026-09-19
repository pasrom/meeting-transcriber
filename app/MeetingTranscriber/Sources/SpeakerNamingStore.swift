import Foundation

/// Disk persistence for a job's speaker-naming sidecars, keyed by a per-job
/// `slug`. Pure I/O over a single `outputDir` (the protocol output folder) —
/// it holds no queue/job state, so naming-persistence behaviour can be
/// unit-tested without constructing a `PipelineQueue`. Extracted from
/// `PipelineQueue` as the first step of unbundling its speaker-naming concern.
///
/// Sidecar layout under `<outputDir>/recordings/`:
/// - `<slug>_naming.json`  — the `SpeakerNamingData` payload (owner-only)
/// - `<slug>_16k.wav`, `<slug>_app_16k.wav`, `<slug>_mic_16k.wav` — audio for re-diarization
/// - `<slug>_segments.json` — cached transcript segments for late re-assignment
struct SpeakerNamingStore {
    /// Protocol output directory; the `recordings/` subfolder holds the
    /// sidecars. `nil` disables all I/O (skeleton queues / tests without an
    /// output dir) — every method is then a no-op.
    let outputDir: URL?

    /// Filesystem slug for a job's persisted artefacts. Embeds the job's
    /// short-id so two back-to-back same-title meetings (e.g. a recurring
    /// "Daily Standup") can't clobber each other on disk and confuse snapshot
    /// rebuild — without it both jobs would resolve to the same
    /// `<title>_naming.json` and the second save would overwrite the first,
    /// then both UUIDs would map to the survivor.
    static func slug(title: String, jobID: UUID, startTime: Date) -> String {
        ProtocolGenerator.basename(
            title: title,
            startTime: startTime,
            shortID: PipelineJob.shortID(for: jobID),
        )
    }

    /// The per-slug sidecars this store owns, as one list so the cleanup and
    /// the tests that pin it cannot drift apart. `namingJSONSuffix` is kept
    /// separate because `deleteNamingJSON` removes only that one.
    static let namingJSONSuffix = "_naming.json"
    static let segmentsSuffix = "_segments.json"
    static let sidecarSuffixes = ["_16k.wav", "_app_16k.wav", "_mic_16k.wav", segmentsSuffix]

    private var recordingsDir: URL? {
        outputDir?.appendingPathComponent("recordings")
    }

    /// Run `body` with the output directory's security scope open.
    ///
    /// Security-scoped access is the caller's job for anything under a
    /// user-picked output folder, and the removals below go through `try?`, so
    /// a sandboxed build without the scope deletes nothing and says nothing.
    /// It sits here rather than at each caller because every site that drops a
    /// job's sidecars would otherwise need its own copy, and all but one never
    /// had one. Opened on `outputDir`, the bookmark-resolved root, not on the
    /// `recordings` child.
    private func withOutputDirAccess<R>(_ body: () throws -> R) rethrows -> R {
        let accessing = outputDir?.startAccessingSecurityScopedResource() ?? false
        defer {
            if accessing {
                outputDir?.stopAccessingSecurityScopedResource()
            }
        }
        return try body()
    }

    // FluidAudio embeddings can contain NaN/Inf for short or silent segments.
    // The default JSON coders reject non-conforming floats — encode/decode them
    // as these string tokens instead. The encode and decode token sets MUST
    // match for embeddings to round-trip, so build both from one place.
    private static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.nonConformingFloatEncodingStrategy = .convertToString(
            positiveInfinity: "Infinity", negativeInfinity: "-Infinity", nan: "NaN",
        )
        return encoder
    }

    private static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.nonConformingFloatDecodingStrategy = .convertFromString(
            positiveInfinity: "Infinity", negativeInfinity: "-Infinity", nan: "NaN",
        )
        return decoder
    }

    /// Persist naming data as `<slug>_naming.json`. Throws on encode/write
    /// failure so the caller can surface a job warning — the store itself stays
    /// I/O-only and queue-state-free. No-op when `outputDir` is `nil`.
    func save(_ data: PipelineQueue.SpeakerNamingData, slug: String) throws {
        guard let recordingsDir else { return }
        try? FileManager.default.createDirectory(at: recordingsDir, withIntermediateDirectories: true)
        let path = recordingsDir.appendingPathComponent("\(slug)\(Self.namingJSONSuffix)")
        let json = try Self.makeEncoder().encode(data)
        try json.write(to: path, options: .atomic)
        // Carries per-speaker voice embeddings — restrict to owner-only.
        try FileManager.default.restrictToOwner(path)
    }

    func load(slug: String) -> PipelineQueue.SpeakerNamingData? {
        guard let recordingsDir else { return nil }
        let path = recordingsDir.appendingPathComponent("\(slug)\(Self.namingJSONSuffix)")
        guard let json = try? Data(contentsOf: path) else { return nil }
        return try? Self.makeDecoder().decode(PipelineQueue.SpeakerNamingData.self, from: json)
    }

    /// Whether a slug still has naming data on disk.
    ///
    /// Read by the snapshot restore: a confirm drops this the moment it has
    /// rewritten the transcript, so finding it means the rewrite did not
    /// happen and the transcript still carries the auto-names.
    func hasNamingData(slug: String?) -> Bool {
        guard let slug, let recordingsDir else { return false }
        return FileManager.default.fileExists(
            atPath: recordingsDir.appendingPathComponent("\(slug)\(Self.namingJSONSuffix)").path,
        )
    }

    /// Delete only the `<slug>_naming.json` sidecar. Audio/segment sidecars are
    /// the concern of `cleanupSidecarFiles`.
    func deleteNamingJSON(slug: String?) {
        guard let slug, let recordingsDir else { return }
        withOutputDirAccess {
            try? FileManager.default.removeItem(
                at: recordingsDir.appendingPathComponent("\(slug)\(Self.namingJSONSuffix)"),
            )
        }
    }

    /// Delete only the cached transcript segments. These contain verbatim
    /// speech, unlike the audio/naming sidecars, and must not outlive a job
    /// when separate raw-transcript output is disabled.
    func deleteTranscriptSegments(slug: String?) throws {
        guard let slug, let recordingsDir else { return }
        let path = recordingsDir.appendingPathComponent("\(slug)\(Self.segmentsSuffix)")
        try withOutputDirAccess {
            guard FileManager.default.fileExists(atPath: path.path) else { return }
            try FileManager.default.removeItem(at: path)
        }
    }

    /// Delete the 16 kHz audio and segment sidecar files for a slug.
    func cleanupSidecarFiles(slug: String?) {
        guard let slug, let recordingsDir else { return }
        withOutputDirAccess {
            for suffix in Self.sidecarSuffixes {
                try? FileManager.default.removeItem(at: recordingsDir.appendingPathComponent("\(slug)\(suffix)"))
            }
        }
    }
}
