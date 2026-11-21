import Foundation

/// Ends of live transcript files still waiting for their events in flight
/// (`LiveTranscriptFile.end(waitingUpTo:)`), and the stop-time caption flushes
/// that start such an end. A coordinator shares one with every controller it
/// builds, so a quit can wait for all of them, a dropped controller's included,
/// and write the rest at the last moment before exit.
@MainActor
final class LiveTranscriptEnds {
    private let work = UnfinishedWork()
    private var waiting: [ObjectIdentifier: LiveTranscriptFile] = [:]

    var isEmpty: Bool {
        work.isEmpty
    }

    /// Ends `file` once its events in flight landed, at most `wait` later.
    func end(_ file: LiveTranscriptFile, waitingUpTo wait: Duration) {
        let id = ObjectIdentifier(file)
        waiting[id] = file
        _ = work.track { [weak self] in
            await file.end(waitingUpTo: wait)
            self?.waiting[id] = nil
        }
    }

    /// Runs a stop-time caption flush as work a quit waits for: it ends the
    /// recording's file on its way.
    func track(_ flush: @escaping @MainActor () async -> Void) {
        _ = work.track(flush)
    }

    /// Returns once every end and flush held here has run, also ones started meanwhile.
    func waitForAll() async {
        await work.waitForAll()
    }

    /// Writes `end` at once to every file still waiting, dropping its events in
    /// flight. For the last synchronous moment before the process exits.
    func endAllNow() {
        for file in waiting.values {
            file.appendEnd()
        }
        waiting.removeAll()
    }
}
