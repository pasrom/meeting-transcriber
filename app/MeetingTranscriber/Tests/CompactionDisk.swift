import Foundation
@testable import MeetingTranscriber
import os
import XCTest

/// Holds a step of the compactor until the test opens it, so a test can act
/// while the run is in the middle of that step.
final class StepGate: Sendable {
    private struct State {
        var reached = 0
        var open = false
        var waiters: [CheckedContinuation<Void, Never>] = []
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    /// How many times a step has arrived at the gate.
    var reached: Int {
        state.withLock(\.reached)
    }

    /// Wait here until `open()`; returns at once once it was opened.
    func pass() async {
        await withCheckedContinuation { continuation in
            let resumeNow = state.withLock { state -> Bool in
                state.reached += 1
                guard !state.open else { return true }
                state.waiters.append(continuation)
                return false
            }
            if resumeNow { continuation.resume() }
        }
    }

    func open() {
        let waiters = state.withLock { state -> [CheckedContinuation<Void, Never>] in
            state.open = true
            defer { state.waiters = [] }
            return state.waiters
        }
        waiters.forEach { $0.resume() }
    }
}

/// A copy of the recordings folder and the registry file, taken at the
/// moment a compactor step is called, and put back later: the state a kill
/// at that moment would leave, produced by the real run rather than seeded.
struct CrashSnapshot: Sendable {
    let name: String
    private let stash: URL
    private let recordings: URL
    private let registryFile: URL

    /// Copy `recordings` and `registryFile` into a new folder under `stashRoot`.
    static func capture(_ name: String, recordings: URL, registryFile: URL, stashRoot: URL) throws -> Self {
        let stash = stashRoot.appendingPathComponent("\(name)-\(UUID().uuidString)", isDirectory: true)
        let fm = FileManager.default
        try fm.createDirectory(at: stash, withIntermediateDirectories: true)
        try fm.copyItem(at: recordings, to: stash.appendingPathComponent("recordings"))
        if fm.fileExists(atPath: registryFile.path) {
            try fm.copyItem(at: registryFile, to: stash.appendingPathComponent("registry.json"))
        }
        return Self(name: name, stash: stash, recordings: recordings, registryFile: registryFile)
    }

    /// Replace the live folder and registry file with the copy.
    func restore() throws {
        let fm = FileManager.default
        try? fm.removeItem(at: recordings)
        try? fm.removeItem(at: registryFile)
        try fm.copyItem(at: stash.appendingPathComponent("recordings"), to: recordings)
        let registryCopy = stash.appendingPathComponent("registry.json")
        if fm.fileExists(atPath: registryCopy.path) {
            try fm.copyItem(at: registryCopy, to: registryFile)
        }
    }
}

/// Reading the state the compactor leaves, from the disk.
enum CompactionDisk {
    /// The registry as saved: it is written synchronously on every change,
    /// so the file is what a kill at this moment would leave.
    static func entries(at registryFile: URL) -> [RetainedRecording] {
        guard let data = try? Data(contentsOf: registryFile) else { return [] }
        return (try? JSONDecoder().decode([RetainedRecording].self, from: data)) ?? []
    }

    /// Every name in `folder`, hidden ones included, sorted.
    static func names(in folder: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).sorted()
    }

    /// The names in `folder` that belong to a recording's kept files: its
    /// tracks in either container, its recording sidecar and partial copies.
    /// Not the speaker-naming files the pipeline keeps beside them, which
    /// the registry never lists.
    static func recordingNames(in folder: URL) -> [String] {
        names(in: folder).filter { name in
            RecordingFileSuffix.keptTrack(of: name) != nil
                || name.hasSuffix(RecordingSidecar.recordingFilenameSuffix)
                || RecordingCompaction.isPartialCopy(name)
        }
    }

    static func listedNames(at registryFile: URL) -> Set<String> {
        Set(entries(at: registryFile).flatMap(\.paths).map(\.lastPathComponent))
    }

    static func exists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }
}

@MainActor
extension RetentionQueueFixture {
    var registryFile: URL {
        logDir.appendingPathComponent(RecordingRetentionRegistry.filename)
    }

    /// A compactor on this fixture's registry, with the FLAC setting read from
    /// `isEnabled` and the codec found available.
    func makeCompaction(
        steps: RecordingCompactionWorker.Steps = .live,
        isEnabled: @escaping () -> Bool = { true },
        now: @escaping () -> Date = Date.init,
        rename: @escaping (URL, URL) throws -> Void = RecordingCompaction.renameExclusive,
        report: @escaping (RecordingCompactionSummary) -> Void = { _ in },
        codec: KeptRecordingCodecStatus = .available,
    ) -> RecordingCompaction {
        let compaction = RecordingCompaction(
            registry: retention.registry,
            isEnabled: isEnabled,
            retentionSettings: { [weak self] in
                self?.retention.effectiveSettings ?? RecordingRetentionSettings(enabled: false, days: 0)
            },
            now: now,
            worker: RecordingCompactionWorker(steps: steps),
            rename: rename,
            report: report,
        )
        compaction.codecStatus = codec
        return compaction
    }

    /// A context for a run on this fixture's output folder outside any queue.
    func compactionContext(excluded: Set<String> = []) -> RecordingCompaction.Context {
        .init(
            excludedPaths: { excluded }, repointJobAudio: { _, _, _ in }, outputRoot: output, scopeRoot: nil,
            securityScope: .live,
        )
    }

    /// Run a 16-bit recording with its sidecar through `queue` to `.done`
    /// and return the job and the WAV tracks it left in the output folder.
    func finishCompactableRecording(in queue: PipelineQueue) async throws -> (job: PipelineJob, tracks: [URL]) {
        let job = try makeRecordedJob(pcm16: true)
        try RecordingSidecar.writeTestRecordingSidecar(besideMix: XCTUnwrap(job.mixPath))
        queue.enqueue(job)
        await queue.processNext()
        let finished = try XCTUnwrap(queue.jobs.first { $0.id == job.id })
        XCTAssertEqual(finished.state, .done)
        return try (finished, relocatedTracks(of: finished))
    }

    var listedNames: Set<String> {
        CompactionDisk.listedNames(at: registryFile)
    }

    /// The visible files of a recording in the recordings folder that the
    /// registry does not list: anything here is out of retention's reach.
    func unlistedRecordingFiles() -> Set<String> {
        Set(CompactionDisk.recordingNames(in: recordingsDir).filter { !$0.hasPrefix(".") }).subtracting(listedNames)
    }

    /// The samples of each file as the app's own loader reads them, for
    /// comparing a track before and after the conversion.
    func samples(of urls: [URL]) throws -> [[Float]] {
        try urls.map { try AudioMixer.loadAudioFileAsFloat32(url: $0) }
    }
}

/// The compressed name of a WAV track, failing the test for any other name.
func compressedTrack(_ wav: URL) throws -> URL {
    try XCTUnwrap(KeptRecordingCompressor.compressedURL(for: wav))
}

@MainActor
extension XCTestCase {
    /// Wait until the compactor has no run going and owes nothing.
    func waitForCompactionIdle(_ compaction: RecordingCompaction) async {
        await waitFor(!compaction.isRunning && compaction.awaitingCount == 0, timeout: .seconds(10))
    }
}

extension RecordingCompactionWorker.Steps {
    /// These steps with the one at `key` replaced.
    func with<Step>(_ key: WritableKeyPath<Self, Step>, _ step: Step) -> Self {
        var steps = self
        steps[keyPath: key] = step
        return steps
    }
}
