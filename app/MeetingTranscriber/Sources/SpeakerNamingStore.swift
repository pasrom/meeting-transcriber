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

    private var recordingsDir: URL? {
        outputDir?.appendingPathComponent("recordings")
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
        let path = recordingsDir.appendingPathComponent("\(slug)_naming.json")
        let json = try Self.makeEncoder().encode(data)
        try json.write(to: path, options: .atomic)
        // Carries per-speaker voice embeddings — restrict to owner-only.
        try FileManager.default.restrictToOwner(path)
    }

    func load(slug: String) -> PipelineQueue.SpeakerNamingData? {
        guard let recordingsDir else { return nil }
        let path = recordingsDir.appendingPathComponent("\(slug)_naming.json")
        guard let json = try? Data(contentsOf: path) else { return nil }
        return try? Self.makeDecoder().decode(PipelineQueue.SpeakerNamingData.self, from: json)
    }

    /// Delete only the `<slug>_naming.json` sidecar. Audio/segment sidecars are
    /// the concern of `cleanupSidecarFiles`.
    func deleteNamingJSON(slug: String?) {
        guard let slug, let recordingsDir else { return }
        try? FileManager.default.removeItem(at: recordingsDir.appendingPathComponent("\(slug)_naming.json"))
    }

    /// Delete the 16 kHz audio and segment sidecar files for a slug.
    func cleanupSidecarFiles(slug: String?) {
        guard let slug, let recordingsDir else { return }
        let suffixes = ["_16k.wav", "_app_16k.wav", "_mic_16k.wav", "_segments.json"]
        for suffix in suffixes {
            try? FileManager.default.removeItem(at: recordingsDir.appendingPathComponent("\(slug)\(suffix)"))
        }
    }
}
