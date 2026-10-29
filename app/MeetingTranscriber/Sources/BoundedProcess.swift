import Foundation
import os

/// A subprocess run with a time limit. `run(timeout:onStop:)` starts it and
/// returns only once it has exited: by itself, after being stopped at the
/// limit, or after being stopped because the calling task was cancelled.
///
/// Stopping sends SIGTERM and, if the process is still running after the
/// grace period, SIGKILL, both to the process group the child leads, so
/// what it started in that group is stopped with it.
final class BoundedProcess: Sendable {
    enum Outcome: Equatable {
        case exited(Int32)
        case timedOut
    }

    static let defaultTerminationGrace: TimeInterval = 1

    /// `timeout` in seconds for messages and logs: "300" for a whole number
    /// of seconds, "0.2" otherwise.
    static func label(for timeout: TimeInterval) -> String {
        timeout == timeout.rounded() ? String(format: "%.0f", timeout) : String(format: "%.1f", timeout)
    }

    private struct State {
        var exited = false
        var stopped = false
        var waiters: [CheckedContinuation<Void, Never>] = []
    }

    let process: Process
    private let terminationGrace: TimeInterval
    private let state = OSAllocatedUnfairLock(initialState: State())

    /// Installs the process's termination handler; set nothing else on
    /// `terminationHandler` afterwards.
    init(_ process: Process, terminationGrace: TimeInterval = defaultTerminationGrace) {
        self.process = process
        self.terminationGrace = terminationGrace
        let state = state
        process.terminationHandler = { _ in
            let waiters = state.withLock { current in
                current.exited = true
                defer { current.waiters = [] }
                return current.waiters
            }
            for waiter in waiters {
                waiter.resume()
            }
        }
    }

    /// Starts the process and waits for it to exit. At `timeout` (on the
    /// suspending clock, so time asleep does not count), or when the calling
    /// task is cancelled, the process is stopped and `onStop` runs. The wait
    /// itself ignores cancellation: it lasts until the process is gone.
    ///
    /// Returns `.timedOut` whenever the process was still running at the
    /// limit, even if it then exits with status 0: what a stopped process
    /// produced may be incomplete. Throws `CancellationError` when
    /// cancelled, and whatever `Process.run()` throws when the process
    /// cannot be started. A process that survives SIGKILL (stuck in
    /// uninterruptible I/O) keeps the wait from ending.
    func run(timeout: TimeInterval, onStop: @escaping @Sendable () -> Void = {}) async throws -> Outcome {
        try Task.checkCancellation()
        try process.run()
        let stopRun: @Sendable () -> Void = { [self] in
            if stop() { onStop() }
        }
        let timer = Task.detached {
            do {
                try await Task.sleep(for: .seconds(timeout), clock: .suspending)
            } catch {
                return
            }
            stopRun()
        }
        defer { timer.cancel() }
        await withTaskCancellationHandler {
            await waitForExit()
        } onCancel: {
            stopRun()
        }
        try Task.checkCancellation()
        return state.withLock { $0.stopped } ? .timedOut : .exited(process.terminationStatus)
    }

    private func waitForExit() async {
        await withCheckedContinuation { continuation in
            let exited = state.withLock { current in
                if !current.exited { current.waiters.append(continuation) }
                return current.exited
            }
            if exited { continuation.resume() }
        }
    }

    /// Sends SIGTERM to the process group, and SIGKILL after the grace
    /// period, each only while no exit is recorded, so neither is meant for
    /// a later process given the same pid. The lock only decides; signals go
    /// out after it is released, so a pid could still be reused between the
    /// two, as it could between Foundation reaping the process and running
    /// its termination handler. Returns whether it signalled; a second call
    /// does nothing.
    private func stop() -> Bool {
        let pid = process.processIdentifier
        let signals = state.withLock { current in
            guard !current.exited, !current.stopped else { return false }
            current.stopped = true
            return true
        }
        guard signals else { return false }
        Self.signalGroup(of: pid, SIGTERM)
        let state = state
        DispatchQueue.global().asyncAfter(deadline: .now() + terminationGrace) {
            if state.withLock({ !$0.exited }) { Self.signalGroup(of: pid, SIGKILL) }
        }
        return true
    }

    /// `Process` starts the child as the leader of a process group of its
    /// own; signal that group, or just the pid if it leads none.
    private static func signalGroup(of pid: pid_t, _ signal: Int32) {
        if getpgid(pid) == pid {
            killpg(pid, signal)
        } else {
            kill(pid, signal)
        }
    }
}
