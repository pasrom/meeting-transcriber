// What a quit waits for, as `AppState` answers it (see `TerminationFlush`).
// It reads `pipeline` at quit time rather than capturing a queue earlier, so
// it follows whichever queue exists by then.
extension AppState: AppTerminating {
    var hasWorkBeforeQuit: Bool {
        pipeline.hasPendingSnapshotWrites
    }

    func flushSnapshotsBeforeQuit() async {
        await pipeline.awaitSnapshotFlushes()
    }

    func tearDownBeforeExit() {
        #if !APPSTORE
            stopPersistentLogStreamer()
        #endif
    }
}
