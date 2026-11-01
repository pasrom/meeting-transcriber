import Foundation

/// One export used up its overall time.
struct NotionExportDeadlineExceeded: Error {}

/// Bounds one export as a whole. The Notion client limits each request, but an
/// export is many of them (a replace of a long page is hundreds), so the sum
/// needs a limit of its own.
enum NotionExportDeadline {
    /// Runs `operation` and gives up on it after `limit`, or as soon as the
    /// calling task is cancelled, whichever comes first.
    ///
    /// The operation is cancelled but not awaited once the race is decided: the
    /// exporter is a protocol, and one that does not look at cancellation would
    /// otherwise keep this call, and the job's export with it, waiting for the
    /// very hang the limit exists for. An abandoned run is stopped at its next
    /// suspension point and its late result is dropped. `TerminationFlush.run`
    /// races a main-actor operation against a timer for the same reason.
    static func run<T: Sendable>(
        limit: Duration,
        operation: @escaping @Sendable () async throws -> T,
    ) async throws -> T {
        let race = Race<T>()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                race.install(continuation)
                race.track(Task {
                    do {
                        let value = try await operation()
                        race.finish(.success(value))
                    } catch {
                        race.finish(.failure(error))
                    }
                })
                race.track(Task {
                    try? await Task.sleep(for: limit)
                    race.finish(.failure(NotionExportDeadlineExceeded()))
                })
            }
        } onCancel: {
            race.finish(.failure(CancellationError()))
        }
    }

    /// Settles once: the first outcome wins, whichever of the operation, the
    /// timer and the cancellation handler reports it, and the tasks still
    /// running are cancelled.
    private final class Race<T: Sendable>: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<T, any Error>?
        private var outcome: Result<T, any Error>?
        private var tasks: [Task<Void, Never>] = []

        func install(_ continuation: CheckedContinuation<T, any Error>) {
            lock.lock()
            if let outcome {
                lock.unlock()
                continuation.resume(with: outcome)
            } else {
                self.continuation = continuation
                lock.unlock()
            }
        }

        func track(_ task: Task<Void, Never>) {
            lock.lock()
            if outcome != nil {
                lock.unlock()
                task.cancel()
            } else {
                tasks.append(task)
                lock.unlock()
            }
        }

        func finish(_ result: Result<T, any Error>) {
            lock.lock()
            guard outcome == nil else {
                lock.unlock()
                return
            }
            outcome = result
            let waiting = continuation
            continuation = nil
            let running = tasks
            tasks = []
            lock.unlock()
            running.forEach { $0.cancel() }
            waiting?.resume(with: result)
        }
    }
}
