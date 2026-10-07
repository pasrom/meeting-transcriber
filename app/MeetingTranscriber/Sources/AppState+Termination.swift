// What a quit waits for, as `AppState` answers it (see `TerminationFlush`).
// All of it reads `watching` and `pipeline` at quit time rather than capturing
// a loop or a queue earlier, so it follows whichever ones exist by then.
extension AppState: AppTerminating {
    var hasWorkBeforeQuit: Bool {
        watching.hasWorkBeforeQuit || pipeline.hasPendingSnapshotWrites
    }

    func finishRecordingBeforeQuit() async {
        await watching.finishForQuit()
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
