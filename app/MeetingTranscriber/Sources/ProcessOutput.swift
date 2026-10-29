import Foundation
import os

/// Reads what a subprocess writes to its pipes with no thread blocked in a
/// read. A process the child started can hold a pipe open after the child
/// has exited, so end of file may never come; each stream can therefore
/// also be ended from outside, which `run` does at the latest a drain grace
/// after the exit.
enum ProcessOutput {
    /// How long output is still read after the process has exited. What it
    /// wrote before exiting is in the pipe by then; this only matters when
    /// end of file does not come.
    static let defaultDrainGrace: TimeInterval = 1

    /// How much of the end of a stream `collectTail` keeps by default.
    static let defaultTailLimit = 64 * 1024

    /// Runs `process` through `BoundedProcess.run(timeout:onStop:)` while
    /// `read` consumes the streams whose `ends` are given.
    ///
    /// `BoundedProcess` returns only once the process has exited, so every
    /// ending below comes after the exit: after a timeout that is up to the
    /// termination grace past the limit. A cancellation stops the reading at
    /// the cancel itself, since `read` runs as a child of the cancelled task;
    /// the streams are ended once the process has exited.
    ///
    /// The streams are ended at once after a failed start, a cancellation, a
    /// timeout, and an exit with status 0 when `drainOnSuccess` is false.
    /// After any other exit they are ended `drainGrace` later. Whatever
    /// `read` left open is ended when it returns. `onCut` is then told which
    /// streams were ended before end of file, in the order of `ends`, unless
    /// none was. Returns once `read` has finished, throwing
    /// `CancellationError` if the task was cancelled by then, so a cancelled
    /// run never returns output.
    static func run<Output: Sendable>(
        _ process: BoundedProcess,
        timeout: TimeInterval,
        onStop: @escaping @Sendable () -> Void = {},
        ending ends: [@Sendable () -> Bool],
        drainGrace: TimeInterval = defaultDrainGrace,
        drainOnSuccess: Bool = true,
        onCut: (_ cut: [Bool]) -> Void,
        read: @Sendable () async -> Output,
    ) async throws -> (outcome: BoundedProcess.Outcome, output: Output) {
        let endAll: @Sendable () -> [Bool] = { ends.map { $0() } }
        async let output = read()
        let outcome: BoundedProcess.Outcome
        do {
            outcome = try await process.run(timeout: timeout, onStop: onStop)
        } catch {
            // On a cancellation the reading stopped with the task, so a
            // process writing more than a pipe buffer while it shuts down
            // blocks until the SIGKILL. Acceptable on this path. Leaving
            // the scope cancels `read` as well; the streams are ended here
            // too so that does not depend on how each reader handles it.
            _ = endAll()
            throw error
        }

        let notCut = [Bool](repeating: false, count: ends.count)
        var drain: Task<[Bool], Never>?
        switch outcome {
        case let .exited(status) where status != 0 || drainOnSuccess:
            drain = Task {
                do {
                    try await Task.sleep(for: .seconds(drainGrace))
                } catch {
                    return notCut
                }
                return endAll()
            }

        case .exited, .timedOut:
            _ = endAll()
        }
        let result = await output
        // Awaited after the cancel, so a drain already ending the streams
        // (perhaps the reason `read` returned) still has its report counted.
        drain?.cancel()
        let endedByDrain = await drain?.value ?? notCut
        let cut = zip(endAll(), endedByDrain).map { $0 || $1 }
        if cut.contains(true) { onCut(cut) }
        try Task.checkCancellation()
        return (outcome, result)
    }

    /// What the process writes to `pipe`, chunk by chunk as it arrives. The
    /// stream ends at end of file, or earlier when `end` is called, which
    /// reports whether it was the one to end it (end of file had not
    /// come). Either way the handler is removed.
    static func chunks(of pipe: Pipe) -> (chunks: AsyncStream<Data>, end: @Sendable () -> Bool) {
        let (chunks, continuation) = AsyncStream<Data>.makeStream()
        let open = OSAllocatedUnfairLock(initialState: true)
        let end: @Sendable () -> Bool = {
            let wasOpen = open.withLock { isOpen in
                defer { isOpen = false }
                return isOpen
            }
            continuation.finish()
            return wasOpen
        }
        let handle = pipe.fileHandleForReading
        continuation.onTermination = { _ in handle.readabilityHandler = nil }
        handle.readabilityHandler = { readable in
            let data = readable.availableData
            if data.isEmpty {
                _ = end()
            } else {
                continuation.yield(data)
            }
        }
        return (chunks, end)
    }

    /// The last `limit` bytes of `chunks`, starting on a UTF-8 character
    /// boundary. Trimmed only once twice the limit has piled up, so a
    /// long stream is not copied on every chunk.
    static func collectTail(of chunks: AsyncStream<Data>, limit: Int = defaultTailLimit) async -> Data {
        var data = Data()
        for await chunk in chunks {
            data.append(chunk)
            if data.count > 2 * limit { data = tail(of: data, limit: limit) }
        }
        return data.count > limit ? tail(of: data, limit: limit) : data
    }

    private static func tail(of data: Data, limit: Int) -> Data {
        Data(data.suffix(limit).drop { $0 & 0xC0 == 0x80 })
    }
}
