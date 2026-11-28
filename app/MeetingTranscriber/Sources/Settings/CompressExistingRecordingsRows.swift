import Foundation
import Observation
import SwiftUI

/// What the "Compress Existing Recordings" rows in Settings → Output →
/// Recording Storage read and do: count what the run would work on, ask
/// for confirmation, start the run, cancel it. The run is the compactor's
/// own (`PipelineController.compressExistingRecordings`), so its progress
/// and summary come from `compaction`; an automatic run going on beside it
/// is not this row's to show or stop.
@MainActor
@Observable
final class CompressExistingRecordingsState {
    let compaction: RecordingCompaction
    /// Bound to the confirmation dialog.
    var isConfirming = false
    /// The count the confirmation names, taken when the button was pressed.
    private(set) var confirmationCount = 0
    /// From the confirmation until the run is entered, the gap before
    /// `RecordingCompaction.requestedRun` says it waits or runs, so a second
    /// press cannot queue a second run in between.
    private(set) var isStarting = false

    /// Whether the user's run is on its way, waiting or running: the rows
    /// show progress and Cancel for it, and keep the button disabled.
    var isBusy: Bool {
        isStarting || compaction.requestedRun != .idle
    }

    @ObservationIgnored private let countCompressible: () -> Int
    @ObservationIgnored private let compress: () async -> Void

    /// Recordings the run would work on, by name only, as of the last
    /// refresh. Kept rather than counted in the body: the registry is not
    /// observable, so a count in the body went stale anyway, and counting
    /// on every redraw (every job update) walked the whole registry.
    /// Refreshed when the rows appear, when any run starts or ends, when a
    /// job finishes or lets go of its tracks (`refreshKey`), when the user's
    /// run returns, and on a press, which so never confirms a stale count.
    private(set) var compressibleCount: Int

    @ObservationIgnored private let heldTracks: () -> Set<String>

    /// `heldTracks` is the tracks the queue's unfinished jobs hold, read
    /// where SwiftUI observes it: it changes when a job finishes or lets go
    /// of its tracks, which starts no run while the FLAC setting is off.
    init(
        compaction: RecordingCompaction,
        countCompressible: @escaping () -> Int,
        heldTracks: @escaping () -> Set<String> = { [] },
        compress: @escaping () async -> Void,
    ) {
        self.compaction = compaction
        self.countCompressible = countCompressible
        self.heldTracks = heldTracks
        self.compress = compress
        compressibleCount = countCompressible()
    }

    /// Bound to `pipeline`'s compactor and its explicit run.
    convenience init(pipeline: PipelineController) {
        self.init(
            compaction: pipeline.recordingCompaction,
            countCompressible: { [weak pipeline] in pipeline?.compressibleRecordingCount ?? 0 },
            heldTracks: { [weak pipeline] in pipeline?.queue.retentionExcludedPaths ?? [] },
            compress: { [weak pipeline] in await pipeline?.compressExistingRecordings() },
        )
    }

    /// What the count's refresh follows: a run starting or ending, and the
    /// tracks unfinished jobs hold. In-memory reads only; the count itself
    /// is what the refresh then reads.
    struct RefreshKey: Hashable {
        let running: Bool
        let held: Set<String>
    }

    var refreshKey: RefreshKey {
        RefreshKey(running: compaction.isRunning, held: heldTracks())
    }

    func refreshCount() {
        let count = countCompressible()
        if count != compressibleCount { compressibleCount = count }
    }

    /// Asks only for a count that is still there: a press on a stale button
    /// just refreshes it, which disables the button with its reason.
    func requestConfirmation() {
        refreshCount()
        guard compressibleCount > 0 else { return }
        confirmationCount = compressibleCount
        isConfirming = true
    }

    /// Start the run. It queues behind a run already going, so it never
    /// converts beside another.
    @discardableResult
    func confirm() -> Task<Void, Never> {
        isStarting = true
        return Task {
            // Same turn as the request reaching the compactor's queue: the
            // way to `run` has no suspension point, so no frame shows the
            // row idle in between. Cleared here and not when the run returns,
            // so a cancel of a waiting run frees the row at once.
            isStarting = false
            await compress()
            refreshCount()
        }
    }

    /// Stop the run this row started, not an automatic one.
    func cancel() {
        compaction.cancelRequestedRun()
    }
}

/// The texts of the rows. Pure, so each wording can be pinned on its own.
enum CompressExistingRecordingsText {
    static let buttonTitle = "Compress Existing Recordings\u{2026}"
    static let confirmationTitle = "Compress existing recordings?"
    static let confirmButtonTitle = "Compress"

    static func confirmationMessage(count: Int) -> String {
        "\(recordings(count)) in the output folder still \(count == 1 ? "has" : "have") WAV tracks. Each track is "
            + "converted to FLAC with exactly the same audio and checked against its WAV before the WAV is removed. "
            + "Only recordings this app recorded and moved into the output folder are converted: imported files, "
            + "record-only recordings, recordings processed by earlier versions, recordings of meetings cancelled "
            + "before their audio reached the output folder, and files renamed by hand stay as they are. Recordings in another output folder, recordings a "
            + "meeting still being processed uses, and files not downloaded from iCloud are skipped. This works "
            + "whether or not \u{201C}Store recordings as FLAC\u{201D} is on."
    }

    /// Why the button cannot be used now, or nil while it can. The count is
    /// asked for only once FLAC is confirmed: it reads the whole registry.
    static func unavailableReason(codec: KeptRecordingCodecStatus, compressibleCount: () -> Int) -> String? {
        switch codec {
        case .unavailable:
            return "Unavailable: this Mac cannot write FLAC."

        case .unknown:
            // The probe is still running, or failed for a reason that says
            // nothing about the codec; the run needs a confirmed FLAC.
            return "Not available until this Mac is confirmed to write FLAC."

        case .available:
            guard compressibleCount() == 0 else { return nil }
            // Not "none is WAV": one a meeting still uses, or retention is
            // about to delete, is WAV and still not counted.
            return "No tracked recording in the output folder can be compressed now."
        }
    }

    static func progress(_ progress: RecordingCompactionProgress?, waiting: Bool = false) -> String {
        if waiting { return "Waiting for another conversion to finish\u{2026}" }
        guard let progress, progress.total > 0 else { return "Compressing recordings\u{2026}" }
        return "Compressing recordings: \(progress.done) of \(files(progress.total)) done."
    }

    /// What the last run the user asked for did.
    static func summary(_ summary: RecordingCompactionSummary) -> String {
        if let notRun = summary.notRun { return "Nothing was compressed: " + notRunReason(notRun) }
        if summary.registryNotSaved { return "Nothing was compressed: the list of tracked recordings could not be saved." }
        let converted = summary.compressed + summary.resumed
        var text = converted == 0 ? "No file was compressed." : "Compressed \(files(converted))"
        if converted > 0 {
            text += summary.bytesSaved > 0
                ? ", saving \(ByteCountFormatter.string(fromByteCount: summary.bytesSaved, countStyle: .decimal))."
                : "."
        }
        let kept = summary.skippedTracks.filter { $0.key != .cancelled }
        if !kept.isEmpty {
            let reasons = RecordingCompactionPlan.TrackSkip.allCases.compactMap { reason in
                kept[reason].map { "\($0) \(trackPhrase(reason))" }
            }
            text += " \(files(kept.values.reduce(0, +))) kept as WAV (\(reasons.joined(separator: ", ")))."
        }
        let skipped = summary.skippedEntries.filter { entryPhrase($0.key) != nil }
        if !skipped.isEmpty {
            let reasons = RecordingCompactionPlan.EntrySkip.allCases.compactMap { reason -> String? in
                guard let count = skipped[reason], let phrase = entryPhrase(reason) else { return nil }
                return "\(count) \(phrase)"
            }
            text += " \(recordings(skipped.values.reduce(0, +))) skipped (\(reasons.joined(separator: ", ")))."
        }
        if summary.cancelled { text += " Cancelled: the rest stays WAV and can be compressed later." }
        return text
    }

    private static func notRunReason(_ reason: RecordingCompactionSummary.NotRun) -> String {
        switch reason {
        case .noFLAC: "this Mac cannot write FLAC."
        case .flacNotConfirmed: "it is not yet confirmed that this Mac can write FLAC."
        case .outputFolderNotOpened: "the output folder could not be opened."
        case .queueStateUnreadable: "the saved meeting queue could not be read, so it is not known which recordings it still needs."
        }
    }

    private static func trackPhrase(_ reason: RecordingCompactionPlan.TrackSkip) -> String {
        switch reason {
        case .notRegularFile: "not a regular file"
        case .evicted: "not downloaded from iCloud"
        case .lowSpace: "not enough free space"
        case .destinationTaken: "a file with the FLAC name exists"
        case .unreadable: "could not be read"
        case .notIntegerPCM: "not 16- or 24-bit audio"
        case .lengthMismatch: "damaged WAV header"
        case .mismatch: "copy did not match"
        case .notNativeFLAC: "FLAC not written"
        case .syncFailed: "could not be saved to disk"
        case .writeFailed: "could not be written"
        case .recheckFailed: "changed during the conversion"
        case .cancelled: "cancelled"
        }
    }

    /// Nil for the reasons that are no news to the user: the run did not
    /// look for them, or there was nothing to do.
    private static func entryPhrase(_ reason: RecordingCompactionPlan.EntrySkip) -> String? {
        switch reason {
        case .notAwaiting, .noWAVTrack: nil
        case .inUse: "in use by a meeting being processed"
        case .otherRoot: "in another output folder"
        case .rootMissing: "output folder not reachable"
        case .due: "about to be deleted by Recording Retention"
        }
    }

    private static func files(_ count: Int) -> String {
        count == 1 ? "1 file" : "\(count) files"
    }

    private static func recordings(_ count: Int) -> String {
        count == 1 ? "1 recording" : "\(count) recordings"
    }
}

/// The button, the confirmation, the progress with Cancel, and the last
/// run's summary. Its own view so the Recording Storage section only places it.
struct CompressExistingRecordingsRows: View {
    let state: CompressExistingRecordingsState

    var body: some View {
        let compaction = state.compaction
        // Not counted during the user's run: the button is disabled then
        // anyway, and the count would be redone for every track it finishes.
        // An automatic run leaves the button usable; a press queues behind it.
        let unavailable = state.isBusy
            ? nil
            : CompressExistingRecordingsText.unavailableReason(codec: compaction.codecStatus) { state.compressibleCount }
        HStack {
            Button(CompressExistingRecordingsText.buttonTitle) { state.requestConfirmation() }
                .disabled(state.isBusy || unavailable != nil)
                .accessibilityIdentifier(A11yID.compressExistingRecordingsButton)
            Spacer()
            if compaction.requestedRun != .idle {
                // Stops after the track in work; what is not converted stays WAV.
                Button("Cancel") { state.cancel() }
                    .accessibilityIdentifier(A11yID.compressExistingRecordingsCancelButton)
            }
        }
        // On appear, and again whenever a run starts or ends or a job
        // finishes or lets go of its tracks.
        .task(id: state.refreshKey) { state.refreshCount() }
        .confirmationDialog(CompressExistingRecordingsText.confirmationTitle, isPresented: Bindable(state).isConfirming) {
            Button(CompressExistingRecordingsText.confirmButtonTitle) { state.confirm() }
        } message: {
            Text(CompressExistingRecordingsText.confirmationMessage(count: state.confirmationCount))
        }

        if state.isBusy {
            caption(
                CompressExistingRecordingsText.progress(compaction.progress, waiting: compaction.requestedRun == .waiting),
                id: A11yID.compressExistingRecordingsProgress,
            )
        } else {
            if let summary = compaction.lastRequestedRun {
                caption(CompressExistingRecordingsText.summary(summary), id: A11yID.compressExistingRecordingsSummary)
            }
            if let unavailable {
                caption(unavailable, id: A11yID.compressExistingRecordingsUnavailable)
            }
        }
    }

    private func caption(_ text: String, id: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .accessibilityIdentifier(id)
    }
}
