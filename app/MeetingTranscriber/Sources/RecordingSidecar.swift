import AudioTapLib
import Foundation
import os.log

private let logger = Logger(subsystem: AppPaths.logSubsystem, category: "RecordingSidecar")

/// Metadata sidecar written next to dual-source recordings. In record-only
/// mode it is `<basename>_meta.json`, consumed by an external
/// transcription/diarization pipeline (e.g. on a Linux GPU host) so it doesn't
/// have to re-detect context the macOS client already knows. A recording the
/// app processes itself carries the same content as
/// `<basename>_recording.json`, for a later re-import.
struct RecordingSidecar: Codable {
    /// Filename suffix appended to the recording basename to form the sidecar
    /// filename (e.g. `20260503_120000` → `20260503_120000_meta.json`).
    static let filenameSuffix = "_meta.json"

    /// The suffix of the sidecar of a recording the pipeline processes. Not
    /// `filenameSuffix`: those recordings end up in the same `recordings/`
    /// folder as record-only output, and a consumer of that folder can take a
    /// new `_meta.json` as the sign that a recording is complete and waiting
    /// for it. A re-import reads it after `filenameSuffix`.
    static let recordingFilenameSuffix = "_recording.json"

    /// Schema version stamped into every new sidecar. Bump when fields are
    /// added/removed/repurposed so downstream consumers can branch on it.
    /// 2 added `trigger`. 3 added `micMuteIntervals`.
    static let currentVersion = 3

    /// How the recording was started. Consumers apply different policies to
    /// the two: a very short auto capture is usually a false trigger worth
    /// discarding, while a short manual recording is deliberate. Without this
    /// the only downstream signal is duration, which cannot tell them apart.
    enum Trigger: String, Codable {
        /// Started by a meeting detector, including browser meetings where the
        /// user only confirmed a consent prompt the detector raised.
        case auto
        /// Started by the user picking an app in the recording picker.
        case manual
    }

    let version: Int
    let title: String
    let appName: String
    let startedAt: Date
    let stoppedAt: Date
    let participants: [String]
    let micDelaySeconds: TimeInterval
    /// Seconds of the mic track the user muted. Nil on sidecars before version 3.
    let micMuteIntervals: [MicMuteInterval]? // swiftlint:disable:this discouraged_optional_collection
    private(set) var files: Files

    /// Raw storage so an unrecognised value decodes as `nil` instead of
    /// throwing. `read()` swallows decode errors, so a strict `Trigger?` would
    /// let one future value discard the entire sidecar on the reimport path
    /// (title, participants and meeting-start included) rather than just the
    /// one field this build cannot interpret.
    private let triggerRaw: String?

    /// `nil` for version 1 sidecars, which predate the field, and for values
    /// introduced by a newer schema version than this build knows.
    var trigger: Trigger? {
        triggerRaw.flatMap(Trigger.init(rawValue:))
    }

    struct Files: Codable {
        let mix: String
        let app: String?
        let mic: String?
    }

    private enum CodingKeys: String, CodingKey {
        case version, title, appName, startedAt, stoppedAt
        case participants, micDelaySeconds, micMuteIntervals, files
        case triggerRaw = "trigger"
    }

    init(
        title: String,
        appName: String,
        startedAt: Date,
        stoppedAt: Date,
        participants: [String],
        micDelaySeconds: TimeInterval,
        trigger: Trigger,
        mixFilename: String,
        appFilename: String?,
        micFilename: String?,
        micMuteIntervals: [MicMuteInterval] = [],
    ) {
        self.version = Self.currentVersion
        self.title = title
        self.appName = appName
        self.startedAt = startedAt
        self.stoppedAt = stoppedAt
        self.participants = participants
        self.micDelaySeconds = micDelaySeconds
        self.micMuteIntervals = micMuteIntervals
        self.triggerRaw = trigger.rawValue
        self.files = Files(mix: mixFilename, app: appFilename, mic: micFilename)
    }

    /// The mute times for a reimport of these tracks. They apply to a mic track
    /// transcribed on its own: with the app track beside it, or in a recording
    /// that never had one. Otherwise the mix is transcribed, which holds the far end.
    func micMuteIntervals(app: URL?, mic: URL?) -> [MicMuteInterval] {
        mic != nil && (app != nil || files.app == nil) ? micMuteIntervals ?? [] : []
    }

    /// Writes the sidecar as `<basename>\(filenameSuffix)` into `directory`.
    /// Returns the resulting URL.
    @discardableResult
    func write(toDirectory directory: URL, basename: String) throws -> URL {
        let url = directory.appendingPathComponent("\(basename)\(Self.filenameSuffix)")
        try write(to: url)
        return url
    }

    /// Writes the sidecar to `url`, owner-only.
    func write(to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(self)
        try data.write(to: url, options: .atomic)
        // Holds meeting title + participants — match the owner-only (0600)
        // treatment of the audio it sits beside.
        try FileManager.default.restrictToOwner(url)
    }

    /// Decode `<directory>/<basename>\(filenameSuffix)`, or nil when missing/malformed.
    static func read(fromDirectory directory: URL, basename: String) -> Self? {
        read(from: directory.appendingPathComponent("\(basename)\(filenameSuffix)"))
    }

    /// The sidecar a re-import of `<directory>/<basename>_*.wav` goes by: the
    /// record-only one, else the one the pipeline keeps beside its recordings.
    static func readForReimport(fromDirectory directory: URL, basename: String) -> Self? {
        read(fromDirectory: directory, basename: basename)
            ?? read(from: directory.appendingPathComponent("\(basename)\(recordingFilenameSuffix)"))
    }

    /// Write the recording sidecar of `recording` beside its mix, for a
    /// dual-source recording the pipeline is about to process. Stage 3 moves
    /// it out of staging with the mix. Without it a later re-import of the
    /// tracks would take the mic offset as zero and lose the mute times. A
    /// recording with one track has no offset to keep and gets none. A failed
    /// write is logged and costs only that re-import.
    static func writeRecordingSidecar(
        for recording: RecordingResult,
        title: String,
        appName: String,
        trigger: Trigger,
        participants: [String],
    ) {
        guard let app = recording.appPath, let mic = recording.micPath,
              let url = recordingSidecarURL(besideMix: recording.mixPath) else { return }
        let sidecar = Self(
            title: title,
            appName: appName,
            startedAt: recording.recordingStartDate,
            // Never before the start, as in record-only: a clock stepped back
            // during the meeting must not make a negative duration.
            stoppedAt: max(Date(), recording.recordingStartDate),
            participants: participants,
            micDelaySeconds: recording.micDelay,
            trigger: trigger,
            mixFilename: recording.mixPath.lastPathComponent,
            appFilename: app.lastPathComponent,
            micFilename: mic.lastPathComponent,
            micMuteIntervals: recording.micMuteIntervals,
        )
        do {
            try sidecar.write(to: url)
        } catch {
            // Redacted: the error names the file, whose name can carry the title.
            logger.warning("Recording sidecar not written: \(error.localizedDescription, privacy: .private)")
        }
    }

    /// The recording sidecar of the recording whose mix is `mix`, a file named
    /// `<stem>_mix.wav`: `<stem>_recording.json` beside it. Nil for any other name.
    static func recordingSidecarURL(besideMix mix: URL) -> URL? {
        guard let (stem, suffix) = RecordingFileSuffix.stripSuffix(from: mix.lastPathComponent),
              suffix == RecordingFileSuffix.mix else { return nil }
        return mix.deletingLastPathComponent().appendingPathComponent(stem + recordingFilenameSuffix)
    }

    /// Rewrite the recording sidecar at `source` as
    /// `<directory>/<stem>_recording.json`, its file names following the
    /// tracks onto `stem`, and remove `source` when that is another file.
    /// Returns the file written. Nil when `source` holds no sidecar this build
    /// can read or the write failed; `source` stays then.
    @discardableResult
    static func moveRecordingSidecar(from source: URL, toDirectory directory: URL, stem: String) -> URL? {
        guard var sidecar = read(from: source) else { return nil }
        sidecar.files = Files(
            mix: stem + RecordingFileSuffix.mix,
            app: sidecar.files.app.map { _ in stem + RecordingFileSuffix.app },
            mic: sidecar.files.mic.map { _ in stem + RecordingFileSuffix.mic },
        )
        let target = directory.appendingPathComponent(stem + recordingFilenameSuffix)
        let fm = FileManager.default
        let replacing = fm.fileExists(atPath: target.path)
        do {
            try sidecar.write(to: target)
        } catch {
            // Written but not made owner-only: still the file to keep. Only
            // when nothing was there before, which could be the old content.
            guard !replacing, fm.fileExists(atPath: target.path) else { return nil }
        }
        if target.standardizedFileURL != source.standardizedFileURL {
            try? fm.removeItem(at: source)
        }
        return target
    }

    /// Decode the sidecar at `url`, or nil when missing/malformed.
    static func read(from url: URL) -> Self? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(Self.self, from: data)
    }
}
