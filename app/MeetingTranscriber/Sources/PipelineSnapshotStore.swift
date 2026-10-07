// The one writer of a pipeline snapshot file.
//
// Every `PipelineQueue` writing to the same directory writes through the same
// store, looked up by that directory on every save. `PipelineController.rebuild()`
// replaces the queue while the replaced one may still be writing the same
// `pipeline_queue.json`, and with a worker per queue the two writes raced: the
// replaced queue's late write could land after the newer one's and put the
// older state back on disk, and the new queue restored the file before the
// older write had landed, so it started from a state already out of date. One
// store per file makes the order on disk the order of the saves, whichever
// queue made them, and lets a restore read the latest saved state while its
// write is still in flight.
//
// The store keeps nothing once its last write has landed: the next save
// creates a fresh one. Nothing holds a store for longer than one write, so two
// stores for one file cannot exist at once.
import Foundation

@MainActor
final class PipelineSnapshotStore {
    typealias Writer = @Sendable ([PipelineJob], URL) throws -> Void

    private static var live: [String: PipelineSnapshotStore] = [:]

    /// The store writing `dir` right now, or nil when every write to it has
    /// landed.
    static func existing(for dir: URL) -> PipelineSnapshotStore? {
        live[key(dir)]
    }

    /// Queue `jobs` for writing into `dir`. Rapid saves coalesce: only the
    /// latest one waiting is written, with the writer it was saved with.
    static func save(_ jobs: [PipelineJob], to dir: URL, using writer: @escaping Writer) {
        let key = key(dir)
        let store = live[key] ?? {
            let created = PipelineSnapshotStore(dir: dir, key: key)
            live[key] = created
            return created
        }()
        // A new state is owed afresh, so it gets a retry of its own.
        store.failedStateRetried = false
        store.save(jobs, using: writer)
    }

    /// Symlinks resolved, so `/var/...` and `/private/var/...` name one file
    /// and get one store.
    private static func key(_ dir: URL) -> String {
        dir.resolvingSymlinksInPath().standardizedFileURL.path
    }

    private let dir: URL
    private let key: String

    // swiftlint:disable discouraged_optional_collection
    /// The latest saved state that is not known to be on disk yet: waiting for
    /// the worker, or being written by it. A restore reads it in place of the
    /// file, which does not hold it yet. Nil means nothing is owed, which is
    /// not the same as owing an empty queue.
    private(set) var latestSaved: [PipelineJob]?
    // swiftlint:enable discouraged_optional_collection

    private var waiting: (jobs: [PipelineJob], writer: Writer)?
    private var worker: Task<Void, Never>?

    /// The writer of the last write, when that write failed and nothing newer
    /// has been saved since. The store then stays: `latestSaved` is still
    /// owed, and a restore or a quit must not take the file for current.
    private var failedWriter: Writer?

    /// Whether a flush has already tried the owed state once more. One retry
    /// per state, however many flushes ask: a quit flushes twice, and a write
    /// that keeps failing (a full disk) would otherwise be tried once per flush.
    private var failedStateRetried = false

    /// Owns the write itself, so a stalled `replaceItemAt` (macOS 26
    /// `mds_stores` rename deadlock) blocks only this actor. The hop to it is a
    /// real suspension, so the detached worker leaves the main actor before
    /// any I/O starts.
    private let writeActor = SnapshotWriterActor()

    private init(dir: URL, key: String) {
        self.dir = dir
        self.key = key
    }

    private func save(_ jobs: [PipelineJob], using writer: @escaping Writer) {
        latestSaved = jobs
        waiting = (jobs, writer)
        guard worker == nil else { return }
        let dir = dir
        let writeActor = writeActor
        // Holds the store strongly: a write is owed whether or not any queue
        // still exists to ask for it.
        worker = Task.detached(priority: .utility) { [self] in
            while let next = await takeNext() {
                let landed = await writeActor.write(jobs: next.jobs, to: dir, using: next.writer)
                await record(landed: landed, writer: next.writer)
            }
        }
    }

    private func takeNext() -> (jobs: [PipelineJob], writer: Writer)? {
        guard let next = waiting else {
            worker = nil
            // A failed write keeps the store, and the state it owes, alive.
            guard failedWriter == nil else { return nil }
            latestSaved = nil
            if Self.live[key] === self { Self.live[key] = nil }
            return nil
        }
        waiting = nil
        return next
    }

    /// Only the outcome of the newest write counts: a newer save waiting
    /// behind a failed one replaces what the failed one owed.
    private func record(landed: Bool, writer: @escaping Writer) {
        failedWriter = landed || waiting != nil ? nil : writer
    }

    /// Return once every save into `dir` has landed, including saves made
    /// while this waited, or once a write that failed has been tried once
    /// more and failed again. In that case the store stays, so the state is
    /// still reported as owed. Not bounded; a caller that must not wait
    /// forever bounds it.
    static func flush(_ dir: URL) async {
        while let store = existing(for: dir), !Task.isCancelled {
            if let worker = store.worker {
                await worker.value
            } else if !store.failedStateRetried, let writer = store.failedWriter, let owed = store.latestSaved {
                store.failedStateRetried = true
                store.save(owed, using: writer)
            } else {
                return
            }
        }
    }
}
