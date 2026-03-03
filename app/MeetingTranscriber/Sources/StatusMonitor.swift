import Foundation
import Observation

/// Watches ~/.meeting-transcriber/status.json for changes using GCD file system events.
@Observable
final class StatusMonitor {
    private(set) var status: TranscriberStatus?
    private(set) var previousState: TranscriberState?

    private let statusFile: URL
    private var fileDescriptor: Int32 = -1
    private var dispatchSource: DispatchSourceFileSystemObject?
    private var pollTimer: DispatchSourceTimer?
    private let queue = DispatchQueue(label: "StatusMonitor", qos: .userInitiated)

    init() {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".meeting-transcriber")
        statusFile = dir.appendingPathComponent("status.json")
    }

    func start() {
        // Try to open immediately; if file doesn't exist yet, poll until it does
        if tryStartWatching() {
            readStatus()
        } else {
            startPolling()
        }
    }

    func stop() {
        dispatchSource?.cancel()
        dispatchSource = nil
        pollTimer?.cancel()
        pollTimer = nil
        if fileDescriptor >= 0 {
            close(fileDescriptor)
            fileDescriptor = -1
        }
    }

    // MARK: - File Watching

    private func tryStartWatching() -> Bool {
        let path = statusFile.path
        let fd = Darwin.open(path, O_EVTONLY)
        guard fd >= 0 else { return false }

        fileDescriptor = fd
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .rename, .delete],
            queue: queue
        )

        source.setEventHandler { [weak self] in
            guard let self else { return }
            let flags = source.data
            if flags.contains(.delete) || flags.contains(.rename) {
                // File was replaced (atomic rename) — reopen
                self.reopenWatch()
            } else {
                self.readStatus()
            }
        }

        source.setCancelHandler { [weak self] in
            if let self, self.fileDescriptor >= 0 {
                Darwin.close(self.fileDescriptor)
                self.fileDescriptor = -1
            }
        }

        source.resume()
        dispatchSource = source
        return true
    }

    private func reopenWatch() {
        dispatchSource?.cancel()
        dispatchSource = nil
        fileDescriptor = -1

        // Small delay for the new file to appear after atomic rename
        queue.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            guard let self else { return }
            if self.tryStartWatching() {
                self.readStatus()
            } else {
                self.startPolling()
            }
        }
    }

    // MARK: - Polling Fallback

    private func startPolling() {
        pollTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: 2.0)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            if self.tryStartWatching() {
                self.pollTimer?.cancel()
                self.pollTimer = nil
                self.readStatus()
            }
        }
        timer.resume()
        pollTimer = timer
    }

    // MARK: - JSON Reading

    private func readStatus() {
        guard let data = try? Data(contentsOf: statusFile),
              let decoded = try? JSONDecoder().decode(TranscriberStatus.self, from: data)
        else { return }

        // Ignore stale status from a dead process
        if let pid = decoded.pid, !Self.processIsAlive(pid) {
            DispatchQueue.main.async { [weak self] in
                self?.previousState = nil
                self?.status = nil
            }
            return
        }

        let oldState = status?.state
        if oldState != decoded.state {
            NSLog("StatusMonitor: \(oldState?.rawValue ?? "nil") → \(decoded.state.rawValue)")
        }
        DispatchQueue.main.async { [weak self] in
            self?.previousState = oldState
            self?.status = decoded
        }
    }

    static func processIsAlive(_ pid: Int) -> Bool {
        kill(Int32(pid), 0) == 0
    }

    /// Parse a status JSON file, returning nil for invalid JSON or dead PIDs.
    static func parseStatus(from url: URL) -> TranscriberStatus? {
        guard let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode(TranscriberStatus.self, from: data)
        else { return nil }

        if let pid = decoded.pid, !processIsAlive(pid) {
            return nil
        }
        return decoded
    }
}
