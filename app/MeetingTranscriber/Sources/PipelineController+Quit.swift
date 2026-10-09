// The pipeline side of a quit (see `TerminationFlush`): whether a snapshot
// write is still owed, and waiting for it.
extension PipelineController {
    // Every queue this controller builds writes the same file, so asking the
    // current queue covers the writes of the queues it replaced as well:
    // they all go through the one `PipelineSnapshotStore` for that file.

    /// Whether a snapshot write has not landed on disk yet.
    var hasPendingSnapshotWrites: Bool {
        queue.isSnapshotWorkerActive
    }

    /// Return once every snapshot write has landed, including one that a
    /// state change made while this was waiting started. Not bounded here;
    /// the caller bounds it (see `TerminationFlush`).
    func awaitSnapshotFlushes() async {
        await queue.awaitSnapshotFlush()
    }
}
