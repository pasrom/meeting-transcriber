import Foundation
import os.log

private let logger = Logger(subsystem: AppPaths.logSubsystem, category: "SpeakerNamingStore")

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
    ///
    /// Opens no security scope of its own. A store on the queue's own output
    /// root is covered by the scope `PipelineQueue` holds for its lifetime. A
    /// store built on a job's recorded `sidecarOutputDir` (restore and its
    /// cleanup) is covered only while that folder is still the current root; an
    /// earlier output folder is unreachable in the sandboxed build, and opening
    /// a scope here would not help, since a URL decoded from the snapshot
    /// carries none.
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
        Self.remove(recordingsDir.appendingPathComponent("\(slug)\(Self.namingJSONSuffix)"))
    }

    /// Delete only the cached transcript segments. These contain verbatim
    /// speech, unlike the audio/naming sidecars, and must not outlive a job
    /// when separate raw-transcript output is disabled.
    func deleteTranscriptSegments(slug: String?) throws {
        guard let slug, let recordingsDir else { return }
        let path = recordingsDir.appendingPathComponent("\(slug)\(Self.segmentsSuffix)")
        guard FileManager.default.fileExists(atPath: path.path) else { return }
        try FileManager.default.removeItem(at: path)
    }

    /// Delete the 16 kHz audio and segment sidecar files for a slug.
    func cleanupSidecarFiles(slug: String?) {
        guard let slug, let recordingsDir else { return }
        for suffix in Self.sidecarSuffixes {
            Self.remove(recordingsDir.appendingPathComponent("\(slug)\(suffix)"))
        }
    }

    /// Best-effort removal. A file that is not there is the normal case (not
    /// every job has every sidecar); any other failure, a missing security
    /// scope among them, is logged rather than dropped. The path is private
    /// because the file name carries the meeting title.
    private static func remove(_ url: URL) {
        do {
            try FileManager.default.removeItem(at: url)
        } catch CocoaError.fileNoSuchFile {
            return
        } catch {
            logger.warning(
                "Could not remove naming sidecar \(url.lastPathComponent, privacy: .private): \((error as NSError).domain, privacy: .public) \((error as NSError).code, privacy: .public)",
            )
        }
    }
}
